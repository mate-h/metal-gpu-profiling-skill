# metal-debug-mcp

An MCP server for Metal GPU debugging on Apple Silicon. It exposes the skill's capture, replay and recording scripts as tools, along with the parts of Xcode's Metal debugger that only the GUI shows. It's a single Swift binary that talks MCP over stdio.

| Tool | What it does | Built on |
|---|---|---|
| `environment` | Checks the Xcode/macOS versions, `gpudebug`, Accessibility, a running xctrace, GPU load, free disk and open captures | |
| `capture` | `.gputrace` of a running app, without Xcode | `scripts/gputrace_capture.sh` (lldb) |
| `list_captures`, `delete_capture` | Manage the server's capture folder. `delete_capture` also clears stale Metal shader archive folders from the user cache | `scripts/gpu_cache_cleanup.sh` |
| `replay_profile` | Replays the capture pass by pass and embeds the profile | `gpudebug` |
| `replay_encoders` | Per-encoder GPU time with no noise from other GPU load, grouped by label. Warns when the replay dropped the render passes | `gpudebug --json` |
| `replay_encoder` | One encoder's limiters, occupancy, instruction count and tile size | `gpudebug` |
| `replay_shaders` | Each shader's cost, registers, spills and instruction mix | `gpudebug` |
| `replay_query` | Raw `gpudebug` commands | `gpudebug` |
| `line_costs` | Per-source-line and per-function shader cost of an encoder's shader (Xcode's source-pane figures), from the embedded profile. CPU only, no GUI | `scripts/shader_line_costs` (Xcode's private profiler frameworks) |
| `compiler_stats` | Compiler statistics and optimizer remarks stored in a capture, when it has them | `scripts/gputrace_stats.py` |
| `record_passes` | Live per-pass time, with counters, from an xctrace Metal System Trace | `scripts/xctrace_profile.sh` |
| `xcode_open` | Opens a capture in Xcode with its profile embedded, in the Performance view | Accessibility |
| `xcode_shaders` | Xcode's Shaders table: cost, allocated registers, spills | Accessibility |
| `xcode_call_stack` | Per-function cost tree of an encoder's fragment, vertex or kernel function, plus the MSL source if asked | Accessibility + mouse clicks |
| `xcode_close` | Closes capture windows | Accessibility |
| `xcode_ui` | Low-level Xcode UI access for when the scripted flow breaks | `scripts/xcode_ax.swift` |

GPU jobs run one at a time. The server queues captures, replays, recordings and Xcode driving, because they disturb each other. `record_passes` refuses while a capture is open in Xcode: driving one hung xctrace saves and skewed timings.

## Requirements

- Apple Silicon, macOS 27.2 or later (for `/usr/bin/gpudebug`), Xcode 27.2 or later, Swift 6.1 or later.
- For `capture`: start the app with `MTL_CAPTURE_ENABLED=1`. lldb must be able to attach to it, which works for apps you built yourself.
- For `xcode_*`: Accessibility permission for the app that runs the server, such as your terminal or Claude. These tools take over the screen while they run: Xcode comes to the front and they click in it.
- For `record_passes` counters: see `../references/counter-profiles.md`. The default counter set (13) is the M5's.

## Build

```bash
cd ~/.claude/skills/metal-gpu-profiling/mcp && swift build -c release
```

The binary is `.build/release/metal-debug-mcp`. It finds the skill's `scripts/` by walking up from its own location. Set `METAL_GPU_SKILL_ROOT` if you move it.

## Add to Claude Code

```bash
claude mcp add metal-debug --scope user -- ~/.claude/skills/metal-gpu-profiling/mcp/.build/release/metal-debug-mcp
```

Any other MCP client can run the same binary over stdio. Recording and replaying can take minutes, so the server sends progress notifications every 10 s when the client asks for them. If your client times out tool calls, raise its timeout (in Claude Code, `MCP_TOOL_TIMEOUT`, in ms).

## Check it works

`metal-debug-sample` is a small app with one labeled compute pass and one labeled render pass:

```bash
swift build -c release && MTL_CAPTURE_ENABLED=1 .build/release/metal-debug-sample &
```

Then call `capture` with its pid, followed by `replay_encoders`, `replay_shaders`, `xcode_open` and `xcode_call_stack` with `encoder_label` `noise_pass`. The kernel's tree should split its cost mostly between `sin` and `cos`.

## Files and settings

- Captures go to `~/Library/Caches/metal-debug-mcp/captures`; set `METAL_DEBUG_MCP_DIR` to move it. Embedding a profile roughly quadruples a small capture, for example 48 MB → 221 MB. Delete captures with `delete_capture`.
- `xcode_ax` is compiled from `../scripts/xcode_ax.swift` on first use and rebuilt whenever that file changes.

## Known limits

- **The `xcode_*` tools depend on Xcode's UI:** labels such as "Open Performance", "Filter the trace list" and "Fragment Function", and the Call Stack popup. An Xcode update can break them. `xcode_ui` (`tree`, `press`, `locate`, `click`, ...) lets you work around a break and find the fix.
- **One capture window at a time.** In the Performance view, a capture window's title is empty, so `xcode_open` closes other capture windows first.
- **`xcode_call_stack` uses the first draw or dispatch** under encoders whose label contains `encoder_label`.
- **No per-line cost.** Accessibility can't map the cost pies to source lines.
- **Replay can silently drop render passes.** `replay_encoders` warns when it does.
