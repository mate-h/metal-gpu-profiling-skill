# Metal captures (.gputrace) without Xcode

## Capturing

1. Start the app with `MTL_CAPTURE_ENABLED=1` and let it warm up. The capture layer is on when
   `[MTLCaptureManager sharedCaptureManager]` is a `CaptureMTLCaptureManager`.
2. `scripts/gputrace_capture.sh <pid> <out.gputrace> [ms]` attaches lldb, starts a capture with
   destination `MTLCaptureDestinationGPUTraceDocument` (2) and `outputURL`, continues the process
   for `ms` (default 40), stops the capture and detaches. The app keeps running.

lldb pitfalls (handled in `gputrace_lldb.py`): use persistent variables (`$cd`), because a local
named `d` collides with target symbols ("Multiple internal symbols found"); evaluate as
Objective-C++ with `@import Metal;` first.

Scope: everything the device submits between start and stop, so several frames at 40 ms. Size is
dominated by the snapshot of every live buffer and texture: ~200 MB for the Bevy atmosphere
example. Delete the capture once the numbers are extracted.

## What is in the bundle

| file | contents |
|---|---|
| `metadata` | binary plist: capture engine settings, frame count, API version |
| `<16 hex digits>` | NSKeyedArchiver plists, one per compiled pipeline function: compiler statistics + optimizer remarks (read by `gputrace_stats.py`) |
| `device-resources-0x…` | resource table: objects, pipeline argument (binding) names, references to the stats ids |
| `capture`, `unsorted-capture`, `index`, `store0`, `delta-device-resources-…` | the API command stream; undocumented binary. Pass labels appear as strings, but the per-dispatch structure isn't decoded |
| `MTLBuffer-<id>-0`, `MTLTexture-<id>-0-mipmapN-sliceN` | raw resource contents at capture start |

Compiler statistics keys include: Instruction count, ALU / FP32 / FP16 / INT16 / INT32 instruction
count, Texture reads / writes, Device load / store, Threadgroup load / store / atomic, Branch
instruction count, Temporary register count, Uniform register count, Spilled bytes, Thread
invariant spilled bytes, Threadgroup memory, Compilation time, Compile Performance (per compiler
pass), and Remarks (LLVM-style optimization remarks with `program_source` line numbers).

## Matching pipelines to passes

Naga names most entry points `main_`. `gputrace_stats.py` prints the binding names that
`device-resources` lists before a stats id, which usually names the pass, but only a few pipelines
are found that way. Otherwise match by shape: instruction mix, texture reads, and the module names
in the remarks (`gputrace_stats.py --remarks <id>`). Two near-identical rows are usually
variants of one pipeline (e.g. shader-def permutations).

Bevy atmosphere example, M5 (Nov 2026): the two largest kernels (~8,200 instructions, 228 texture
reads, 126 temporary registers, 80 bytes spilled) are the clouds_raymarch variants; the haze
fragment shader is ~17,000 instructions of ALU at 61 registers.

## What it can't give

Per-draw GPU time, counters and shader cost come from a replay of the capture. `gpudebug`
(macOS 27.2) gives per-draw times and counters from the CLI. With that profile embedded,
`scripts/shader_line_costs` prints per-line and per-function shader cost, the numbers in Xcode's
source pane, without the GUI. See `references/xcode-gpu-debugger.md`.
Xcode's MCP server (`xcrun mcpbridge`) has no tool for capture or the Metal debugger.
