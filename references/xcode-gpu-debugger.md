# Replayed GPU profiles: gpudebug and Xcode's Metal debugger

A replay of a `.gputrace` runs each pass alone, so its times don't move when other apps share the
GPU, which xctrace recordings do. It also gives per-draw shader counters, per-function shader
cost, register counts and spills. Learned on an M5 with macOS 27.2 and Xcode 27.2 (Nov 2026).

## Capture

- Use `scripts/gputrace_capture.sh <pid> <out> 400` on an app started with `MTL_CAPTURE_ENABLED=1`.
  - **400 ms** worked at 2560x1440 on a Bevy scene running about 40 ms per frame. 100 ms held a
    partial frame (3 draws). At 1.5 s, `stopCapture` hung past lldb's expression timeout and left
    an unreadable bundle.
  - A 400 ms capture is 1.2–1.6 GB. Delete it when done.
- `/usr/bin/gpucapture start --pid ...` (macOS 27.2) stalled twice while snapshotting resources
  (about 1,456 of 1,980), even with a 15 min limit. Use the lldb script instead.
- Check that the pass you care about is in the capture before profiling:
  `LC_ALL=C grep -ac '<pass label>' <trace>/unsorted-capture`.

## gpudebug (CLI replay, macOS 27.2)

```bash
gpudebug --oneshot -q -t x.gputrace -c "profile run --exec serial --gpu-state high --embed"   # 5-15 s
gpudebug --oneshot -q -t x.gputrace -c "profile load" -c "go performance" -c "go encoders" -c "list" \
  -c "go .." -c "go shaders" -c "list"
```

- Run `profile run` and the listing as **two separate invocations**. Listing in the same call as
  `profile run` printed empty tables.
- `--embed` stores the profile in the trace, so Xcode opens it straight into its Performance view.
- Navigate one level at a time (`go performance`, `go encoders`). Absolute paths like
  `go /performance/x` error; `go /` and `go ..` work. `go` also prints the node it lands on.
- Sessions die with the shell, so always use `--oneshot`. The `-o` flag is ignored in oneshot
  mode. Fetched files land in `$(getconf DARWIN_USER_TEMP_DIR)gpudebug_out/`; clean it up.
- Output has `\r` progress lines: pipe it through `tr '\r' '\n' | awk '!seen[$0]++'`. With
  `--json` don't dedupe: repeated listings are identical lines and the awk drops them.
- `--json` prints one JSON value per listing (`{"children": [{"name", "values": [...]}]}`, values
  positional in the text table's column order) and per `info`.
- **You get:** serial per-encoder Vertex/Fragment/Compute ms, per-draw and per-kernel cost, and
  per-draw counters (instruction mix, for example 50% integer and conditional ALU in a water
  shader). `info <encoder>` under `performance/encoders` gives that encoder's limiters (F32,
  instruction throughput, texture read/filtering/cache, ...), occupancy, instruction count and
  tile size, measured on the replay, so they don't mix with concurrent passes like xctrace's
  GPU-wide counters. `info <shader>` under `performance/shaders` gives temporary/uniform
  registers, spilled bytes and the instruction mix, even for captures without the compiler
  statistics files `gputrace_stats.py` reads (a small Metal app's capture had none).
- **You don't get:** per-line or per-function shader cost, which the CLI doesn't expose.
  Heatmaps exist but are tile-sampled and nearly uniform.
- **Pitfall:** the replay can silently drop every render command buffer. Two captures of a
  modified build listed only the compute passes, while a capture of the unmodified build
  replayed fully. The label was in `unsorted-capture` and the app rendered fine. No error was
  printed, even without `-q`, and the cause is unknown. Always check that the encoder list
  contains the pass before reading numbers. If it doesn't, fall back to xctrace A/B runs.

## Xcode: per-function cost and registers

`open -a Xcode x.gputrace`. With an embedded profile, Xcode opens straight to Performance.

| What | Where in Xcode | Read with `scripts/xcode_ax` |
|---|---|---|
| Cost, registers, spills per shader | Performance > **Shaders** button | `xcode_ax shaders` (0.2 s) |
| Per-function inclusive cost tree | shader source pane, popup **Source Files → Call Stack** | `xcode_ax callstack` (0.8 s) |
| Shader source (MSL) | shader source pane | `xcode_ax source out.metal` |
| Anything else | | `xcode_ax tree [depth]` |

Getting to the shader source pane:
1. Show the navigator.
2. Type the pipeline label into the Debug navigator's filter field ("Filter the trace list").
3. Click the draw row (`drawIndexedPrimitives…`).
4. In Bound Resources, double-click the **Fragment Function** row.

Double-clicking a row in the Shaders table does not open the source.

The whole loop runs from the CLI with `xcode_ax` (tested Nov 2026, under 30 s end to end once
Xcode has the capture open). The MCP server in `mcp/` runs exactly this as `xcode_open` and
`xcode_call_stack`:

```bash
open -a Xcode x.gputrace                       # it opens on Summary
xcode_ax wait "Open Performance" 120; xcode_ax press "Open Performance"
xcode_ax wait Shaders 120; xcode_ax press Shaders; xcode_ax shaders
xcode_ax press Navigators                      # toggles; only if "Filter the trace list" is missing
xcode_ax filter composite_pass                 # the navigator's filter, then Return
xcode_ax activate; xcode_ax click $(xcode_ax locate "[draw" --contains) 1     # "[dispatch" for compute
xcode_ax wait "Fragment Function" 30           # "Vertex Function", "Kernel Function"
xcode_ax activate; xcode_ax click $(xcode_ax locate "Fragment Function") 2
xcode_ax choose "Source Files" "Call Stack"; xcode_ax callstack tree.txt
```

(In zsh, split the coordinates: `xy=$(xcode_ax locate ...); xcode_ax click ${xy% *} ${xy#* } 1`.)

- A double-click that lands too far right on a row does nothing. Aim near the label (x ≈ 400 for
  Bound Resources rows; `locate` aims at most 200 pt in from a row's left edge), and bring Xcode
  to the front first.
- Selecting a navigator row through accessibility (`xcode_ax select`, setting `AXSelected`)
  succeeds but doesn't navigate: the draw needs a real click.
- With the navigator hidden, the Performance view's own "Filter the profiling timeline" field is
  the only filter field. `filter` therefore targets "Filter the trace list" by name and fails when
  the navigator is hidden.
- In the Performance view, a capture window's title is empty and it has no `AXDocument`.
  `xcode_ax windows` tells capture windows apart by their debugger controls ("Open
  Performance", "Stop GPU workload", a "Performance" jump-bar popup), and `raise` / `close`
  take a window index (`#0`). With two captures open you can't tell which is which, so keep one
  open at a time.

Build the reader once:

```bash
swiftc -O ~/.claude/skills/metal-gpu-profiling/scripts/xcode_ax.swift -o <scratch>/xcode_ax
```

The terminal needs Accessibility permission.

- **Use the compiled AX tool, not osascript.** System Events and JXA took 30–150 s per query on
  Xcode's large UI tree and often timed out, especially over the Debug navigator's 700+ rows. The
  Swift tool reads the whole window in about 1 s.
- **Clicking:** System Events `click` works for buttons and menus. Double-clicks need real events
  (`CGEvent` with `mouseEventClickState` 2), and those reach Xcode. Use `AXPress` where offered:
  table rows have no actions.
- Xcode must be frontmost for element positions to update after scrolling.
- **Close the capture in Xcode before recording with xctrace.** With a profiled capture open and
  being driven, two xctrace recordings hung for 15 min while saving, and a third measured a pass at
  a third of its usual time. Measure with xctrace and inspect in Xcode at separate times.
- Pick the main window (`AXMainWindow`). Tooltips show up as the first entry in `AXWindows`.
- The Shaders table counts registers differently from `gputrace_stats.py`. One water shader
  showed 252 allocated registers and 3.08 KiB spilled there, against 126 temporary registers and
  3,152 stack bytes in the compiler statistics.

## Per-line cost: don't spend time on it through accessibility

The source pane draws a cost pie on each costed line (elements with `AXIdentifier`
`CostElement<pct>`, about 500 for a 4,400-line shader). The values can be read, but not which line
each belongs to:
- Pie views are recycled. Hidden ones keep stale positions, and several report the same height.
- `AXVisibleChildren` is empty.
- Pressing a pie doesn't move the selection.
- Lines wrap, and `AXBoundsForRange` is valid only near the visible range.

Mapping by position put the 100% pie on an unrelated local variable. Reading the pies from
screenshots has the same line-mapping problem. **The
per-function Call Stack tree is the reliable level.** Pair it with the MSL from
`xcode_ax source` and the WGSL to see which statements a function holds.

## Reading the costs

- Percentages are inclusive shares of the shader's sampled cost, not time a change will save.
  In a latency-bound shader (low limiters, about 20% occupancy, 252 registers), replacing a
  function listed at 18% saved 3% of the pass. An ablation that removed it outright saved 6%.
  Use the tree to choose targets, then measure the change with alternated runs.
- Per-function rows repeat under each call site, such as `water_foam_and_depth` called twice.
  Sum them before ranking.
- What paid off instead was cutting spills. In the same shader, sharing one LOD slice choice
  across six texture reads cut spills from 3,120 to 816 bytes per thread, at the same 126
  registers. The pass went from 26 to 8.9 ms. Track `spill` in `gputrace_stats.py` for each change:
  in a latency-bound shader it predicts cost far better than the function percentages.
