# metal-gpu-profiling

A Claude Code skill for profiling and optimizing GPU work on Apple Silicon (Bevy, wgpu or any Metal app). It measures exact per-pass GPU time from `xctrace` Metal System Trace tables instead of guessing from FPS or ablation builds. It also reads hardware counters (limiters, occupancy, bandwidth) and shader compiler statistics, and lists the Apple-GPU optimizations that measurably paid off.

Claude loads `SKILL.md` automatically when a task involves GPU profiling on a Mac. This README is for people. Claude doesn't read it.

## Install

Clone it into your user skills folder:

```bash
git clone https://github.com/mate-h/metal-gpu-profiling-skill.git ~/.claude/skills/metal-gpu-profiling
```

The skill is picked up from the next Claude Code session onward, in every project.

## Keeping machines in sync

Pull before using it on a machine:

```bash
git -C ~/.claude/skills/metal-gpu-profiling pull --ff-only
```

After editing it, commit and push from the skill folder:

```bash
cd ~/.claude/skills/metal-gpu-profiling && git commit -am "describe change" && git push
```

If the pull refuses because both machines have local commits, run `git pull --rebase` and push.

## Requirements

- macOS on Apple Silicon with Xcode installed (`xcrun xctrace`). GPU counters on the M5 need Xcode 27.2 and macOS 27.2. Launch the Instruments GUI once per machine so it installs its GPU system components.
- Python 3 with `numpy`, for the counter parser.
- Debug labels on your render and compute passes. Unlabeled passes can't be attributed.

## Layout

| Path | What it is |
| --- | --- |
| `SKILL.md` | The instructions Claude follows: recording procedure, cleanup, reading the numbers, finding cost inside a pass, reporting |
| `scripts/xctrace_profile.sh` | One-shot measurement: launch or attach, warm up, record, export, print the per-pass table and counters, delete the trace |
| `scripts/xctrace_passes.py` | Joins GPU intervals with encoder labels into per-pass ms/frame and medians |
| `scripts/xctrace_counters.py` | Per-pass GPU counters and per-shader time from a counter recording |
| `scripts/xctrace_template.py` | Copies the Metal System Trace template with a chosen counter set |
| `scripts/gputrace_capture.sh`, `gputrace_lldb.py` | Metal frame capture (`.gputrace`) of a running app without Xcode, via lldb |
| `scripts/gputrace_stats.py` | Per-pipeline registers, spills, instruction mix and optimizer remarks from a capture |
| `scripts/xcode_ax.swift` | Reads Xcode's Metal debugger views through the accessibility API (`swiftc -O xcode_ax.swift -o xcode_ax`) |
| `references/apple-gpu-patterns.md` | Measured wins and non-wins on Apple GPUs |
| `references/counter-profiles.md` | Picking a GPU counter set from the CLI, and finding its number on a new machine |
| `references/gputrace.md` | Captures and their statistics |
| `references/xcode-gpu-debugger.md` | Replayed profiles with `gpudebug` and Xcode's Metal debugger |

## Running the profiler by hand

```bash
S=/path/to/scratch WARM=45 SECS=2 FRAME=<once-per-frame pass label> \
  ~/.claude/skills/metal-gpu-profiling/scripts/xctrace_profile.sh <binary> [args...]
```

See the header of `scripts/xctrace_profile.sh` for all options (`PID=` to attach to a running app, `COUNTERS=0`, `COUNTER_PROFILE`, `GPU_IDLE`, `KEEP_XML`).

Recordings are large. A trace is 0.3–3 GB, and each one leaves a raw `instruments*.ktrace` of 0.5–5 GB in the per-user temp folder. The script deletes both when it finishes. Only one recorder can run on a machine at a time.

## License

MIT. See [LICENSE](LICENSE).
