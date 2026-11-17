// metal-debug-mcp: an MCP server (stdio) for Metal GPU debugging on Apple Silicon. It captures
// .gputrace files from running apps, replays them with gpudebug for noise-free per-encoder times,
// counters and shader statistics, records live per-pass times with xctrace, and drives Xcode's
// Metal debugger through accessibility for what only the GUI shows (per-function shader cost).
// Built on the scripts of the metal-gpu-profiling skill it lives in.
import Foundation
import MCP

let instructions = """
Metal GPU debugging on this Mac. Typical flow: environment → start the app with MTL_CAPTURE_ENABLED=1 \
and let it warm up → capture(pid) → replay_encoders (find the expensive pass) → replay_encoder \
(its limiters: the bound unit) → replay_shaders (registers, spills, instruction mix) → optionally \
xcode_open + xcode_call_stack for the per-function cost inside one shader. record_passes measures a \
live app with xctrace instead (moves with other GPU load; alternate old/new runs). Captures are large: \
delete_capture when done. GPU jobs run one at a time. The xcode_* tools take over the screen.
"""

let paths: Paths
do { paths = try Paths.resolve() } catch {
    FileHandle.standardError.write("metal-debug-mcp: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let server = Server(
    name: "metal-debug-mcp",
    version: "0.1.0",
    instructions: instructions,
    capabilities: .init(tools: .init(listChanged: false))
)
let handlers = Handlers(paths: paths, gate: GPUGate(), server: server)

await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
await server.withMethodHandler(CallTool.self) { params in
    do {
        let text = try await handlers.call(params.name, params.arguments ?? [:], progress: params._meta?.progressToken)
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    } catch {
        return .init(content: [.text(text: "\(error)", annotations: nil, _meta: nil)], isError: true)
    }
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
