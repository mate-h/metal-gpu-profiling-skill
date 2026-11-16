---
name: metal-gpu-profiling
description: Profile and optimize GPU work on Apple Silicon / Metal (Bevy, wgpu, or any Metal app) with the xctrace CLI and Metal System Trace — exact per-pass GPU times from the trace tables, A/B comparisons that survive a noisy shared GPU, cleanup of multi-GB trace residue, and the Apple-GPU optimization patterns that actually paid off. Use this whenever the user asks to profile, measure, speed up, or find the bottleneck of a render/compute pass, shader, frame time or GPU cost on a Mac, mentions xctrace, Instruments, Metal System Trace, GPU counters, limiters, occupancy, register spills, shader instruction counts, Metal frame capture / .gputrace, gpudebug or gpucapture, per-function or per-line shader cost, Xcode's Metal debugger or MCP server, Tracy GPU zones, GPU timestamps on Metal, or says something is "slow on the GPU" — even if they don't say "Metal" or "profile".
---

# Metal GPU profiling and optimization

The goal is **exact, per-pass GPU time read from xctrace's tables**, not guesses from ablation builds or whole-frame FPS. Then optimize the biggest pass, re-measure the same way, and keep only changes that clear the noise floor.

Everything here was learned the hard way on an M5 and an M1 Pro Mac whose GPU was shared with other apps and with other agents profiling at the same time. Most rules exist because the naive version silently produced garbage numbers, killed another recording, or filled the disk.

## What works and what doesn't

- **Per-pass time:** `xctrace record --template 'Metal System Trace' --attach <pid>` from the CLI, then `xctrace export` of `metal-gpu-intervals` (per-encoder Vertex/Fragment/Compute rows with `encoder-id`) joined with `metal-application-encoders-list` (`encoder-id` → `encoder-label`).
- **Hardware counters and per-shader time:** record with a copy of the Metal System Trace template whose GPU counter settings select a counter set by number (`scripts/xctrace_template.py`; the bundled script does this by default). Don't use `--instrument 'Metal GPU Counters'`: on the M5 it picks a counter set that records nothing, and it adds a second counter instance next to the template's own. It fills:
  - `gpu-counter-info` / `gpu-counter-value`: counters sampled GPU-wide over time. About 31 on the M1 Pro and 88 on the M5. They cover limiters and utilization for the ALU (M5: instruction throughput, F32/F16, integer, control flow), texture reads and their cache, writes, buffers, L1, the last-level cache and the MMU; occupancy per stage; register-pressure and memory-stall "influence"; bandwidth. Names differ between generations (`Texture Sample Limiter` vs `Texture Read Limiter`, `Compute Occupancy` vs `Kernel Occupancy`); `xctrace_counters.py` maps both.
  - `metal-shader-profiler-intervals`: a shader timeline, GPU time per shader entry point (`haze (0)`, `main_ (2)`). On the M5 it is filled in some recordings and empty in others.
  - `gpu-shader-profiler-interval` / `-sample`: program-counter samples per shader, mapped to address ranges in `metal-shader-profiler-shader-list`. That gives instruction-level hot spots, but no source lines without shader debug info.
- **Counter set numbers are per GPU.** The counter set is `counterprofile` in the template. On the **M5** (G17G, Xcode 27.2, macOS 27.2) **Performance Limiters is 13**; on older setups 3 was Performance Limiters. The recorded trace's TOC names the set that was used ("Counter Set: ..."), and the script prints it. If it isn't the set you meant, set `COUNTER_PROFILE`. To learn the number for a new machine, pick the set in the Instruments GUI, save a template there (File > Save As Template), and read `counterprofile` from it (`references/counter-profiles.md`).
- **Prerequisites that made the M5 work (Nov 2026):** Xcode 27.2 (26.4 rejects every counter set: "Selected counter profile is not supported on target device"), macOS 27.2, and launching the Instruments GUI once, which installs GPU system components ("Installing System Components..."). Before that GUI install every set gave no counters or only "RT Unit Active", and no error. Check once per machine with a 1 s recording and list the names in `gpu-counter-info`; a row count alone misleads (one counter still gives ~250k value rows).
- **Dead ends for counters (don't retry):** `MTLDevice.counterSets` (the public API exposes only a `timestamp` set on the M5, unrelated to Instruments' counter sets), `sysctl wq.perf_counters` (no such OID). The template's counter device can stay 0 (default); the GPU `registryID` changes across reboots, so templates saved from the GUI go stale.
- **Shader compiler statistics from a Metal capture.** `scripts/gputrace_capture.sh <pid> <out.gputrace>` captures ~40 ms of a running app without Xcode (start the app with `MTL_CAPTURE_ENABLED=1`; lldb drives `MTLCaptureManager`). `scripts/gputrace_stats.py <out.gputrace>` prints each compiled pipeline's temporary/uniform registers, spilled bytes, instruction mix (ALU, F32/F16, texture reads, device loads, branches), threadgroup memory and compile time; `--remarks <id>` prints the optimizer remarks (inlining, spill/reload copies, source lines). This is static per-shader data, complementary to the counters. Matching rows to passes is partial: entry points are mostly `main_`, and binding names are found for only some pipelines. A capture is ~200 MB; delete it after. See `references/gputrace.md`.
- **Xcode's MCP server (`xcrun mcpbridge`, Xcode 27.2) has no GPU tools.** Its 56 tools build, run, test, drive lldb, search docs, render previews and edit projects. None of them captures a frame or reads Metal debugger results.
- **Replayed profiles (macOS 27.2).** `gpudebug` replays a capture pass by pass. That gives noise-free per-encoder and per-draw times plus per-draw counters, but no per-line or per-function shader cost. With the profile embedded in the capture, Xcode shows each shader's per-function cost tree, its registers and its spills. `scripts/xcode_ax.swift` reads those views through the accessibility API in under a second, where osascript took minutes. Per-line costs can't be mapped to lines through accessibility, so don't try. Watch for one pitfall: the replay can silently drop the render passes. See `references/xcode-gpu-debugger.md`.
- **Doesn't work. Don't spend time retrying:**
  - Tracy GPU zones and Bevy `time_span` / wgpu timestamp queries inside passes. Apple GPUs only report timestamps at pass boundaries (no `TIMESTAMP_QUERY_INSIDE_ENCODERS`). Bevy's `RenderDiagnosticsPlugin` is already part of `RenderPlugin`, and adding it again panics. wgpu pass timestamps for render passes are also wrong on Apple's tile-based GPUs (29 ms reported vs 1.6 ms in the trace).
  - Launching the app *under* xctrace (`--launch`). It records no GPU intervals or crashes on save. Always attach to an already-running, warmed-up process.
  - `graphics-compiler-spill-events` when attaching: shaders compile before the recorder attaches, so the table stays empty. Spills need a recording that covers pipeline compilation.

## The recording procedure

Use the bundled script, which encodes every rule below: `scripts/xctrace_profile.sh`. Read its header for options. Typical use:

```bash
S=<scratch folder> WARM=45 SECS=2 FRAME=<label of a once-per-frame pass> \
  ~/.claude/skills/metal-gpu-profiling/scripts/xctrace_profile.sh <binary> [args...]
```

It prints a per-pass table (ms/frame, median per execution, executions/frame, channel, label) with the GPU busy time per frame. With counters (default; `COUNTERS=0` to skip; `COUNTER_PROFILE` picks the set, `PSTATE=3` pins the GPU at its maximum performance state) it then prints the counter set it recorded, the per-pass counter table and the shader timeline. It deletes the trace, exports and raw ktrace afterwards. The counter parser needs numpy; the script picks the first Python that has it (`PY=` to choose one). With counters, a 1 s recording is about 100 MB of trace and 0.5 GB of XML, and the parse takes about 25 s, so keep `SECS` at 1–2. If you write your own flow, keep these rules — each one was a real failure:

1. **Labels first.** Passes need debug labels or the encoder list is useless. In Bevy, label render/compute passes and build with labels kept (e.g. Bevy's `debug` feature). Unlabeled GPU rows can't be attributed; skip them rather than guessing.
2. **Warm up before attaching.** Pipeline compilation can take 20+ s (Bevy blocks in `prepare_view_upscaling_pipelines`); a capture earlier than that measures startup. Start the app normally in the background (`$!` for its PID), wait (`WARM`, 40–60 s for heavy scenes), confirm it's still alive, then attach.
3. **Run xctrace in the foreground with a generous alarm.** `perl -e 'alarm 600; exec @ARGV' xcrun xctrace record ...`. Saving a 2–3 s Metal System Trace can take 4–5+ minutes and looks like a hang — it isn't. Never background xctrace with `&` + `wait` (broke every recording). It genuinely hangs only if the app quits mid-recording, so don't kill the app until record returns.
4. **One recorder at a time machine-wide.** kperf is exclusive and concurrent Metal System Traces corrupt each other. Before recording, loop `while pgrep -qx xctrace; do sleep 15; done`. A lost race shows `could not lock kperf` / "Failed to start" in the record log and still writes an empty trace — check the log, don't trust exit code alone.
5. **Wait for an idle GPU.** Other apps (and other agents' profiling runs) may share it. Poll `ioreg -r -c IOAccelerator -d 1` for `"Device Utilization %"` and wait for ≤ ~20% on a few consecutive samples.
6. **Never `pkill -f` / `pgrep -f` a pattern that also appears in your own command line** — it matches (and kills) your own shell or another agent's shell. Track processes by `$!`; if you must match, use bracketed patterns like `pgrep -f "[x]ctrace record"`, and prefer `pgrep -x xctrace`.
7. **Short recordings.** 1–2 s is plenty (dozens of frames) and keeps save time and size down; longer ones take many minutes to save and parse.
8. **Name copied binaries carefully.** The process name is the binary's file name (`atm_old`, not `atmosphere`), so match by PID (the script does) or by that name.

## Cleanup (traces are huge; don't leave them behind)

- Every recording leaves a raw `instruments*.ktrace` (0.5–5 GB) in the **global** per-user temp dir (`getconf DARWIN_USER_TEMP_DIR`), written by `DTServiceHub`; setting `TMPDIR` for xctrace does not reliably move it. Snapshot `instruments*.ktrace` before recording, and after export delete only the new ones that `lsof` shows nobody holds (another live recording may own one).
- Delete the `.trace` bundle (0.3–3 GB) and XML exports as soon as the numbers are extracted. Never let traces pile up across a batch.
- Use `rm -rf "${S:?}/c.trace"`-style guarded paths; bare `$S/*` globs get blocked by safety checks.
- After a batch, check `df -h /System/Volumes/Data` and report residue.

## Reading the numbers

`scripts/xctrace_passes.py` does the join: for each labeled encoder and channel, take the envelope of its depth-0 intervals, then report the median per execution and the total per frame. Frames are counted from the start times of a once-per-frame pass (`--frame <label>`), one start per encoder; pick a cheap, always-present pass.

- **Envelopes overlap.** A pass's envelope includes time it spends running alongside other passes. So per-pass numbers overstate the pass's own cost and don't add up to the frame. Example: a LUT pass dropped by 0.5 ms per frame while total GPU busy dropped by only 0.2 ms. Back frame-level claims with the **GPU busy (union)** line.
- **Absolute numbers drift between recording sessions.** The same binary and scene read 0.44 ms in one session and 1.5 ms an hour later. Compare only old/new pairs alternated within one session.

Treat results like a noisy experiment:
- **Noise is large.** When other GPU apps are running, all passes move together by 10–40% between runs, sometimes 2–4×. Medians of exact per-encoder times move only a few percent run-to-run when the GPU is quiet, but cross-run comparisons still need care.
- **A/B by alternation.** Run old, new, old, new — not all-old then all-new. Check that *untouched* passes (composite, sky, post) match between runs before trusting a diff in the touched one; if they don't, the run was disturbed. Normalize by a stable reference pass if needed. Only trust changes beyond the observed noise (often ~25% on ratios when the machine is busy, a few % on quiet medians).
- **A/B builds.** Build the old commit into a copied binary. If `Cargo.lock` is gitignored, copy it into the worktree, or the worktree resolves newer dependencies and renders differently. With a shared `CARGO_TARGET_DIR`, cargo may reuse one artifact for both trees — verify the binaries differ (md5, or `grep -a` for an embedded shader string). Runtime-loaded shaders/assets need an asset root holding the old copies (a folder of symlinks + old shader files).
- **Verify the image too.** A faster pass that renders differently isn't a win. Capture an in-app screenshot (e.g. Bevy `Screenshot::primary_window()` + `save_to_disk` from an env-gated system, with time/sun frozen); same-binary runs are bit-identical, so any diff is real. An in-app capture is also more reliable than OS screen capture, which may be blocked or need permissions.
- **CPU side:** when GPU-bound, CPU time piles up in `finish_command_buffers` / `queue_submit` / extract. That's waiting, not cost. Use Tracy for CPU zones and frame pacing (`trace_tracy` feature, `TRACY_NO_EXIT=1`, `tracy-capture`, cut warm-up from the data).

## Finding cost inside a pass

Use the counters first; ablations are a fallback for GPUs without counter support.

- **Find the bottleneck from the limiters.** A limiter near 100% (texture sample or cache, ALU, last-level cache, buffer reads) names the bound unit. Optimize that unit's work: fewer, smaller or half-precision taps when texture-bound; less math when ALU-bound.
- **Low limiters everywhere plus low occupancy (around 10%) means latency-bound.** The usual cause is register pressure. Confirm it with the register budget below before acting. Raising occupancy is not guaranteed to pay: a cloud raymarch at 26% ALU, 11% texture and 10% compute occupancy (register tier 384) gained only 2–8% at 18% occupancy. Long dependent step chains with little work per step stay latency-bound even then; the lever there is fewer steps, or less live state shared between phases.
- **Bandwidth.** Compare read GB/s with the chip's peak (M1 Pro ~200 GB/s).
- **Occupancy over the pass, not just its mean.** Split each execution into time slices and average the counter samples per slice (counters sample every ~36 µs, so a 5 ms pass gets ~140 samples).
  - A flat low plateau means a resource (register) limit.
  - High occupancy at the start with a long low tail means a few long threads (divergent ray lengths).
  - Near-zero compute occupancy at the start of a compute pass's interval is waiting on the previous pass, not its own cost.
- **Register budget of a kernel.** First choice: `gputrace_stats.py` on a capture gives temporary registers and spilled bytes for every pipeline at once (above). To test changes without a rebuild, get the MSL wgpu generated from `RUST_LOG=wgpu_hal::metal=debug` (a "Naga generated shader for entry point …" block per pipeline). Compile it with `MTLDevice.makeLibrary(source:)` in a small Swift tool and read `maxTotalThreadsPerThreadgroup`: 1024 means unconstrained, and it falls as registers per thread rise.
  - **Pitfall:** naga writes `[[max_total_threads_per_threadgroup(X*Y)]]` from `@workgroup_size`, so an 8×8 kernel reports 64 whatever its registers. Strip the attribute first.
  - To find what holds registers, edit the MSL and recompile (seconds per variant): `break` out of a loop, or stub a function. A stub must return a plausible non-zero value. Returning 0 where it zeroes density lets the compiler drop all downstream lighting and shows a false win.
- **Forcing occupancy rarely pays.** A larger `@workgroup_size` raises that attribute and forces the compiler under a register budget, so it spills. A cloud raymarch went from 10% to 18% occupancy this way but only 2–8% faster, and a concurrent pass got slower.
- **Counters are GPU-wide.** Trust rows of passes that dominate their time span, such as big compute passes. Vertex rows of small render passes (bloom, fullscreen triangles) mostly measure whatever runs alongside them.
- **Where inside a shader.** Use the shader timeline to rank entry points; the PC samples give instruction-level hot spots by address.
- **Ablation (no counters, or to confirm a lever):** disable or simplify one piece and re-measure the same pass. To avoid a rebuild per variant:
  - for runtime-loaded shaders, edit the asset and re-run the same binary;
  - for embedded shaders, add a temporary env-var shader def so one build covers several variants.

  Remove the overrides afterwards.

## Apple-GPU optimizations that paid off

Read `references/apple-gpu-patterns.md` before proposing optimizations. It lists measured wins and non-wins from past work (HSR and `discard`, in-pass vs deferred lighting, quad overshading, texture formats, skipping static work), so you can start from what's known to matter.

## Reporting

For each experiment report: the pass, before → after medians (ms), the GPU busy (union) change, the pass's bound unit from the counters, how many alternated runs, whether control passes were stable, the visual check result, and whether the change was kept or reverted. Record durable findings (numbers, kept/reverted decisions, open leads) in the project's memory so the next session doesn't re-measure them.
