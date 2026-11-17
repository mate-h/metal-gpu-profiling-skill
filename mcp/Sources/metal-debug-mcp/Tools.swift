import ApplicationServices
import Foundation
import MCP

// MARK: - Schema and argument helpers

typealias Args = [String: Value]

private func prop(_ type: String, _ description: String, _ extra: [String: Value] = [:]) -> Value {
    var o: [String: Value] = ["type": .string(type), "description": .string(description)]
    for (k, v) in extra { o[k] = v }
    return .object(o)
}

private func schema(_ props: [String: Value] = [:], required: [String] = []) -> Value {
    .object([
        "type": "object",
        "properties": .object(props),
        "required": .array(required.map { .string($0) }),
    ])
}

private extension Args {
    func string(_ k: String) -> String? { self[k]?.stringValue }
    func int(_ k: String) -> Int? {
        if let i = self[k]?.intValue { return i }
        if let d = self[k]?.doubleValue { return Int(d) }
        return self[k]?.stringValue.flatMap { Int($0) }
    }
    func bool(_ k: String) -> Bool? { self[k]?.boolValue }
    func strings(_ k: String) -> [String]? {
        guard case .array(let a)? = self[k] else { return nil }
        return a.compactMap { $0.stringValue }
    }
    func need(_ k: String) throws -> String {
        guard let s = string(k), !s.isEmpty else { throw ToolError("missing argument \(k)") }
        return s
    }
    func needInt(_ k: String) throws -> Int {
        guard let i = int(k) else { throw ToolError("missing integer argument \(k)") }
        return i
    }
}

/// Doubles as their shortest decimal form (2.2349, not 2.2349000000000001).
private func tidy(_ v: Any) -> Any {
    switch v {
    case let d as [String: Any]: return d.mapValues(tidy)
    case let a as [Any]: return a.map(tidy)
    case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID() && CFNumberIsFloatType(n):
        let x = n.doubleValue
        return x.isFinite ? NSDecimalNumber(string: "\(x)") : NSNull()
    default: return v
    }
}

func jsonText(_ raw: Any) -> String {
    let v = tidy(raw)
    guard JSONSerialization.isValidJSONObject(v),
          let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return String(describing: v) }
    return String(decoding: d, as: UTF8.self)
}

// MARK: - Tool list

let tools: [Tool] = [
    Tool(
        name: "environment",
        description: "Check this Mac's GPU debugging setup: Xcode and macOS versions, gpudebug, Accessibility permission (needed by the xcode_* tools), whether an xctrace recording is running, GPU utilization, free disk, open captures in Xcode, and the server's capture folder. Call it first.",
        inputSchema: schema(),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "capture",
        description: "Capture a .gputrace of a running Metal app without Xcode (lldb attaches and drives MTLCaptureManager). The app must have been started with MTL_CAPTURE_ENABLED=1 and be warmed up. 100 ms holds a few frames of a light app; use ~400 ms for a ~40 ms/frame scene (too short captures hold partial frames; 1.5 s hung). Captures are 50 MB to 1.6 GB: delete them with delete_capture when done.",
        inputSchema: schema([
            "pid": prop("integer", "process id of the running app"),
            "ms": prop("integer", "how long to capture, in milliseconds (default 100)"),
            "name": prop("string", "file name in the capture folder (default <process>-<time>)"),
        ], required: ["pid"])
    ),
    Tool(
        name: "list_captures",
        description: "List the captures in the server's capture folder with their size and whether a replay profile is embedded.",
        inputSchema: schema(),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "delete_capture",
        description: "Delete a capture from the server's capture folder (captures elsewhere are left alone).",
        inputSchema: schema(["capture": prop("string", "capture path or name")], required: ["capture"]),
        annotations: .init(destructiveHint: true)
    ),
    Tool(
        name: "replay_profile",
        description: "Replay a capture pass by pass on the GPU (gpudebug, serial, high GPU state) and embed the profile in the trace. The replay_* and xcode_* tools run it on demand; call it directly to re-profile (force) or to time it. 5 s to a few minutes.",
        inputSchema: schema([
            "capture": prop("string", "capture path or name"),
            "force": prop("boolean", "re-profile even if a profile is already embedded"),
        ], required: ["capture"])
    ),
    Tool(
        name: "replay_encoders",
        description: "Per-encoder GPU time from a replayed capture: each pass runs alone, so the times don't move when other apps share the GPU (unlike xctrace). Grouped by label by default (count, median and total vertex/fragment/compute ms). Warns when the replay dropped the render passes, a known silent failure.",
        inputSchema: schema([
            "capture": prop("string", "capture path or name"),
            "group": prop("boolean", "group repeated encoders by label (default true)"),
        ], required: ["capture"]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "replay_encoder",
        description: "Hardware counters of one replayed encoder: limiters (ALU, F32, texture read/filtering/cache, ...), occupancy, instruction count, duration, tile size. Pass the encoder id from replay_encoders (ce0, re3) or its label.",
        inputSchema: schema([
            "capture": prop("string", "capture path or name"),
            "encoder": prop("string", "encoder id (re0, ce2) or label"),
        ], required: ["capture", "encoder"]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "replay_shaders",
        description: "Every shader in a replayed capture with its share of GPU cost, pipeline, invocations and compiler statistics: temporary/uniform registers, spilled bytes, instruction mix (ALU, FP32/FP16, INT, texture reads/writes, device loads/stores, branches), threadgroup memory. Spills predict cost in latency-bound shaders far better than function percentages.",
        inputSchema: schema(["capture": prop("string", "capture path or name")], required: ["capture"]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "replay_query",
        description: "Run raw gpudebug commands on a capture and get every JSON value they print. Nodes: / (commands, performance, api_calls, resources), /performance (timeline, encoders, commands, shaders). Commands: list, go <node>, go .., info <node>, find <text>, status, help. Start with \"profile load\" to use the embedded profile. Navigate one level per go.",
        inputSchema: schema([
            "capture": prop("string", "capture path or name"),
            "commands": prop("array", "gpudebug commands, in order", ["items": ["type": "string"]]),
        ], required: ["capture", "commands"]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "compiler_stats",
        description: "Per-pipeline compiler statistics stored in the capture file itself (registers, spills, instruction mix, compile time), and with remarks_id the optimizer remarks (inlining, spill/reload copies, source lines). Only some captures contain them; replay_shaders gives the statistics for any capture.",
        inputSchema: schema([
            "capture": prop("string", "capture path or name"),
            "remarks_id": prop("string", "pipeline id from the table, to print its optimizer remarks"),
        ], required: ["capture"]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "record_passes",
        description: "Exact per-pass GPU time of a live app with an xctrace Metal System Trace (attaches to a warmed-up process), optionally with hardware counters per pass and the shader timeline. Live timings move with other GPU load: compare old/new builds by alternating runs. Saving the trace takes minutes. Refuses while a capture is open in Xcode (it hung recordings); close it with xcode_close.",
        inputSchema: schema([
            "pid": prop("integer", "process id of the running, warmed-up app"),
            "seconds": prop("integer", "recording length (default 2; keep 1-2 with counters)"),
            "frame_label": prop("string", "label of a pass that runs once per frame, for ms/frame"),
            "counters": prop("boolean", "record GPU counters (default true)"),
            "counter_profile": prop("integer", "counter set number (default 13 = Performance Limiters on the M5; differs per GPU)"),
            "pstate": prop("integer", "induced GPU performance state: 0 default, 3 maximum"),
            "top": prop("integer", "rows per table (default 25)"),
        ], required: ["pid"])
    ),
    Tool(
        name: "xcode_open",
        description: "Open a capture in Xcode's Metal debugger with its replay profile embedded (profiling first if needed) and switch to the Performance view. Takes over the screen: Xcode comes to the front and later xcode_* tools click in it.",
        inputSchema: schema([
            "capture": prop("string", "capture path or name"),
            "profile": prop("boolean", "embed a replay profile first if missing (default true)"),
        ], required: ["capture"])
    ),
    Tool(
        name: "xcode_shaders",
        description: "Xcode's Performance > Shaders table for the open capture: cost, function, stage, pipeline, SIMD groups, allocated registers, highest register, spilled bytes. Xcode counts registers differently from replay_shaders (allocated vs temporary).",
        inputSchema: schema(["capture": prop("string", "capture whose Xcode window to use (default: the front one)")]),
        annotations: .init(readOnlyHint: true)
    ),
    Tool(
        name: "xcode_call_stack",
        description: "Per-function inclusive cost tree of the shader used by an encoder, from Xcode's shader source pane (Call Stack view). Drives the GUI: filters the Debug navigator by the encoder label, clicks its first draw or dispatch, opens the fragment/vertex/kernel function and reads the tree. Percentages are shares of sampled cost, not savings; functions called twice appear twice, so sum them. Per-line cost isn't available.",
        inputSchema: schema([
            "encoder_label": prop("string", "label of the render or compute encoder (as in replay_encoders)"),
            "stage": prop("string", "fragment, vertex or kernel (default: fragment for render passes, kernel for compute)", ["enum": ["fragment", "vertex", "kernel"]]),
            "capture": prop("string", "capture whose Xcode window to use (default: the front one)"),
            "save_source": prop("boolean", "also save the shader's MSL source to a file and return its path"),
        ], required: ["encoder_label"])
    ),
    Tool(
        name: "xcode_close",
        description: "Close capture windows in Xcode (all of them unless one is titled after the given capture; in the Performance view their titles are empty). Do this before record_passes.",
        inputSchema: schema(["capture": prop("string", "capture path or name (default: every capture window)")])
    ),
    Tool(
        name: "xcode_ui",
        description: "Low-level access to Xcode's UI through accessibility, for when the scripted xcode_* flow breaks (Xcode updates move things). Runs scripts/xcode_ax with these arguments: tree [depth], press <name>, choose <shown> <item>, locate <text> [--contains], click <x> <y> [n], filter <text>, wait <name> [secs], windows, raise <title>, activate, callstack, shaders, source <out>.",
        inputSchema: schema([
            "args": prop("array", "xcode_ax arguments", ["items": ["type": "string"]]),
        ], required: ["args"])
    ),
]

// MARK: - Handlers

struct Handlers: Sendable {
    let paths: Paths
    let gate: GPUGate
    let server: Server

    func call(_ name: String, _ a: Args, progress: ProgressToken?) async throws -> String {
        switch name {
        case "environment": return try await environment()
        case "list_captures": return listCaptures()
        case "delete_capture": return try deleteCapture(try a.need("capture"))
        case "compiler_stats": return try await compilerStats(try paths.capture(try a.need("capture")), a.string("remarks_id"))
        case "xcode_ui": return try await gate.exclusive("xcode_ui") { try await xcodeUI(a.strings("args") ?? []) }
        default: break
        }
        // Everything else uses the GPU or drives Xcode: one at a time.
        return try await gate.exclusive(name) {
            try await withHeartbeat(server, progress, name) {
                switch name {
                case "capture":
                    return try await capture(pid: try a.needInt("pid"), ms: a.int("ms") ?? 100, name: a.string("name"))
                case "replay_profile":
                    return try await replayProfile(try paths.capture(try a.need("capture")), force: a.bool("force") ?? false)
                case "replay_encoders":
                    return try await replayEncoders(try paths.capture(try a.need("capture")), group: a.bool("group") ?? true)
                case "replay_encoder":
                    return try await replayEncoder(try paths.capture(try a.need("capture")), try a.need("encoder"))
                case "replay_shaders":
                    return try await replayShaders(try paths.capture(try a.need("capture")))
                case "replay_query":
                    let t = try paths.capture(try a.need("capture"))
                    return jsonText(try await GPUDebug.json(t, a.strings("commands") ?? []))
                case "record_passes":
                    return try await recordPasses(a)
                case "xcode_open":
                    return try await xcodeOpen(try paths.capture(try a.need("capture")), profile: a.bool("profile") ?? true)
                case "xcode_shaders":
                    return try await xcodeShaders(a.string("capture"))
                case "xcode_call_stack":
                    return try await xcodeCallStack(a)
                case "xcode_close":
                    return try await xcodeClose(a.string("capture"))
                default:
                    throw ToolError("unknown tool \(name)")
                }
            }
        }
    }

    // MARK: Environment and captures

    func environment() async throws -> String {
        var env: [String: Any] = [:]
        let xcode = try await run("/usr/bin/xcrun", ["xcodebuild", "-version"], timeout: 60)
        env["xcode"] = xcode.stdout.split(separator: "\n").joined(separator: " ")
        env["macos"] = (try await run("/usr/bin/sw_vers", ["-productVersion"])).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        env["chip"] = (try await run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        env["gpudebug"] = FileManager.default.isExecutableFile(atPath: GPUDebug.exe)
        env["accessibility_trusted"] = AXIsProcessTrusted()
        env["xctrace_running"] = (try await run("/usr/bin/pgrep", ["-x", "xctrace"])).status == 0
        let ioreg = try await run("/usr/sbin/ioreg", ["-r", "-c", "IOAccelerator", "-d", "1"])
        if let r = ioreg.stdout.range(of: #""Device Utilization %"=([0-9]+)"#, options: .regularExpression) {
            env["gpu_utilization_pct"] = Int(ioreg.stdout[r].split(separator: "=").last ?? "")
        }
        if let free = try? paths.work.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            env["disk_free_gb"] = Int(free / 1_000_000_000)
        }
        env["busy_with"] = await gate.current ?? NSNull()
        env["xcode_capture_windows"] = await openCaptureWindows()
        env["skill"] = paths.skill.path
        env["capture_folder"] = paths.captures.path
        var notes: [String] = []
        if !AXIsProcessTrusted() {
            notes.append("xcode_* tools need Accessibility permission for the app that runs this server (System Settings > Privacy & Security > Accessibility)")
        }
        if !(env["gpudebug"] as? Bool ?? false) { notes.append("no /usr/bin/gpudebug: replay_* tools need macOS 27.2 or later") }
        env["notes"] = notes
        return jsonText(env)
    }

    func listCaptures() -> String {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: paths.captures.path)) ?? []).filter { $0.hasSuffix(".gputrace") }.sorted()
        let rows: [[String: Any]] = names.map { n in
            let p = paths.captures.appendingPathComponent(n).path
            let date = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? Date.distantPast
            return ["name": n, "path": p, "size_mb": megabytes(sizeOnDisk(p)), "profiled": GPUDebug.isProfiled(p),
                    "modified": ISO8601DateFormatter().string(from: date)]
        }
        return jsonText(["folder": paths.captures.path, "captures": rows])
    }

    func deleteCapture(_ arg: String) throws -> String {
        let p = try paths.capture(arg)
        let inside = URL(fileURLWithPath: p).standardizedFileURL.path
            .hasPrefix(paths.captures.standardizedFileURL.path + "/")
        guard inside else { throw ToolError("\(p) is outside the server's capture folder; delete it yourself") }
        let size = megabytes(sizeOnDisk(p))
        try FileManager.default.removeItem(atPath: p)
        return jsonText(["deleted": p, "freed_mb": size])
    }

    func capture(pid: Int, ms: Int, name: String?) async throws -> String {
        guard kill(pid_t(pid), 0) == 0 else { throw ToolError("process \(pid) is not running") }
        let ps = try await run("/bin/ps", ["eww", "-o", "command=", "-p", "\(pid)"])
        let enabled = ps.stdout.contains("MTL_CAPTURE_ENABLED=1")
        let comm = (try await run("/bin/ps", ["-o", "comm=", "-p", "\(pid)"])).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let proc = URL(fileURLWithPath: comm).lastPathComponent
        let stamp = { () -> String in
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
        }()
        var file = name ?? "\(proc)-\(stamp)"
        if !file.hasSuffix(".gputrace") { file += ".gputrace" }
        let out = paths.captures.appendingPathComponent(file).path
        if FileManager.default.fileExists(atPath: out) { throw ToolError("\(out) already exists") }
        let r = try await run("/bin/sh", [paths.script("gputrace_capture.sh"), "\(pid)", out, "\(ms)"], timeout: 420)
        guard FileManager.default.fileExists(atPath: out) else {
            var msg = "no capture written:\n\(r.combined)"
            if !enabled { msg += "\nThe process environment has no MTL_CAPTURE_ENABLED=1: restart the app with it." }
            throw ToolError(msg)
        }
        return jsonText(["path": out, "name": file, "size_mb": megabytes(sizeOnDisk(out)), "ms": ms, "process": proc,
                         "next": "replay_encoders / replay_shaders, or xcode_open; delete_capture when done"])
    }

    func compilerStats(_ trace: String, _ remarks: String?) async throws -> String {
        var args = ["-I", paths.script("gputrace_stats.py"), trace]
        if let remarks { args += ["--remarks", remarks] }
        let r = try await run("/usr/bin/python3", args, timeout: 300)
        guard r.ok else { throw ToolError(r.combined) }
        var text = r.stdout
        if text.hasPrefix("0 pipelines") {
            text += "\nThis capture has no stored compiler statistics. replay_shaders gives registers, spills and the instruction mix for any capture."
        }
        return text
    }

    // MARK: Replay

    func ensureProfiled(_ trace: String) async throws {
        if !GPUDebug.isProfiled(trace) { _ = try await GPUDebug.profile(trace) }
    }

    func replayProfile(_ trace: String, force: Bool) async throws -> String {
        if GPUDebug.isProfiled(trace) && !force {
            return jsonText(["capture": trace, "profiled": true, "note": "already profiled; pass force to re-run"])
        }
        let start = Date()
        let out = try await GPUDebug.profile(trace)
        return jsonText(["capture": trace, "profiled": GPUDebug.isProfiled(trace),
                         "seconds": Int(Date().timeIntervalSince(start)), "gpudebug": out])
    }

    private func encoderRows(_ trace: String) async throws -> (status: [String: Any], rows: [[String: Any]]) {
        try await ensureProfiled(trace)
        let out = try await GPUDebug.json(trace, ["profile load", "status", "go performance", "go encoders", "list"])
        let status = out.compactMap { $0 as? [String: Any] }.first { $0["summary"] != nil } ?? [:]
        let rows = GPUDebug.rows(out.last, columns: ["label", "cost_pct", "vertex_ms", "fragment_ms", "compute_ms"])
        return (status, rows)
    }

    func replayEncoders(_ trace: String, group: Bool) async throws -> String {
        let (status, rows) = try await encoderRows(trace)
        var result: [String: Any] = ["capture": trace, "device": status["device"] ?? NSNull(),
                                     "summary": status["summary"] ?? NSNull()]
        let summary = status["summary"] as? String ?? ""
        let draws = Int(summary.range(of: #"([0-9]+) draw calls?"#, options: .regularExpression)
            .map { summary[$0].split(separator: " ")[0] } ?? "") ?? 0
        let renderRows = rows.filter { ($0["fragment_ms"] is Double) || ($0["vertex_ms"] is Double) }
        if draws > 0 && renderRows.isEmpty {
            result["warning"] = "The capture has \(draws) draw calls but the replay profiled no render encoders: gpudebug silently dropped the render passes. Don't read render numbers from this replay; recapture, or use record_passes."
        }
        if !group {
            result["encoders"] = rows
            return jsonText(result)
        }
        var order: [String] = []
        var groups: [String: [[String: Any]]] = [:]
        for r in rows {
            let label = GPUDebug.baseLabel(r["label"] as? String ?? "?")
            if groups[label] == nil { order.append(label) }
            groups[label, default: []].append(r)
        }
        result["passes"] = order.map { label -> [String: Any] in
            let g = groups[label]!
            var p: [String: Any] = ["label": label, "count": g.count, "ids": g.compactMap { $0["id"] },
                                    "cost_pct": round4(g.compactMap { $0["cost_pct"] as? Double }.reduce(0, +))]
            for ch in ["vertex", "fragment", "compute"] {
                let xs = g.compactMap { $0["\(ch)_ms"] as? Double }
                if let m = median(xs) {
                    p["\(ch)_ms_median"] = round4(m)
                    p["\(ch)_ms_total"] = round4(xs.reduce(0, +))
                }
            }
            return p
        }.sorted { ($0["cost_pct"] as? Double ?? 0) > ($1["cost_pct"] as? Double ?? 0) }
        return jsonText(result)
    }

    func replayEncoder(_ trace: String, _ encoder: String) async throws -> String {
        var id = encoder
        if !(encoder.range(of: #"^[a-z]{2}[0-9]+$"#, options: .regularExpression) != nil) {
            let (_, rows) = try await encoderRows(trace)
            guard let r = rows.first(where: { ($0["label"] as? String) == encoder })
                    ?? rows.first(where: { GPUDebug.baseLabel($0["label"] as? String ?? "") == encoder }),
                  let rid = r["id"] as? String else {
                throw ToolError("no encoder labeled \(encoder); labels: \(Set(rows.compactMap { $0["label"] as? String }).sorted().prefix(40))")
            }
            id = rid
        }
        try await ensureProfiled(trace)
        let out = try await GPUDebug.json(trace, ["profile load", "go performance", "go encoders", "info \(id)"])
        guard let info = out.last as? [String: Any], info["children"] == nil else {
            throw ToolError("gpudebug returned no info for \(id)")
        }
        var r = GPUDebug.plainInfo(info)
        r["id"] = id
        return jsonText(r)
    }

    func replayShaders(_ trace: String) async throws -> String {
        try await ensureProfiled(trace)
        let list = try await GPUDebug.json(trace, ["profile load", "go performance", "go shaders", "list"])
        let rows = GPUDebug.rows(list.last, columns: ["function", "pipeline", "cost_pct", "invocations"])
        let ids = rows.compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { return jsonText(["capture": trace, "shaders": []]) }
        let out = try await GPUDebug.json(trace, ["profile load", "go performance", "go shaders"] + ids.map { "info \($0)" })
        let infos = out.suffix(ids.count).map { ($0 as? [String: Any]).map(GPUDebug.plainInfo) ?? [:] }
        let shaders: [[String: Any]] = zip(rows, infos).map { row, info in
            var s = info
            s["cost_pct"] = nil; s["invocations"] = nil   // repeated, rounded, from the list row
            for (k, v) in row { s[k] = v }
            return s
        }
        return jsonText(["capture": trace, "shaders": shaders])
    }

    // MARK: xctrace

    func recordPasses(_ a: Args) async throws -> String {
        let pid = try a.needInt("pid")
        guard kill(pid_t(pid), 0) == 0 else { throw ToolError("process \(pid) is not running") }
        let open = await openCaptureWindows()
        if !open.isEmpty {
            throw ToolError("captures are open in Xcode (\(open.joined(separator: ", "))): driving one hung xctrace saves and skewed timings. Close them with xcode_close first.")
        }
        var env = ["S": paths.recordings.path, "PID": "\(pid)", "SECS": "\(a.int("seconds") ?? 2)",
                   "COUNTERS": (a.bool("counters") ?? true) ? "1" : "0", "TOP": "\(a.int("top") ?? 25)"]
        if let f = a.string("frame_label") { env["FRAME"] = f }
        if let c = a.int("counter_profile") { env["COUNTER_PROFILE"] = "\(c)" }
        if let p = a.int("pstate") { env["PSTATE"] = "\(p)" }
        let r = try await run("/bin/sh", [paths.script("xctrace_profile.sh")], env: env, timeout: 2400)
        if r.timedOut { throw ToolError("recording timed out:\n\(r.combined.suffix(3000))") }
        guard r.ok else { throw ToolError("recording failed (exit \(r.status)):\n\(r.combined.suffix(3000))") }
        return r.stdout
    }

    // MARK: Xcode GUI

    @discardableResult
    func ax(_ args: [String], timeout: Double = 120, check: Bool = true) async throws -> Output {
        let exe = try await paths.ensureXcodeAx()
        let r = try await run(exe, args, timeout: timeout)
        if check && !r.ok { throw ToolError("xcode_ax \(args.joined(separator: " ")): \(r.combined)") }
        return r
    }

    struct XcodeWindow { let index: Int; let main: Bool; let title: String }

    /// Xcode windows showing a capture. In the Performance view a capture window's title is
    /// empty, so xcode_ax recognizes them by their Metal debugger controls.
    func captureWindows() async -> [XcodeWindow] {
        guard xcodeIsRunning(), let r = try? await ax(["windows"], check: false) else { return [] }
        return r.stdout.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, f[1] == "capture", let i = Int(f[0]) else { return nil }
            return XcodeWindow(index: i, main: f[2] == "main", title: f.count > 3 ? f[3] : "")
        }
    }

    func openCaptureWindows() async -> [String] {
        await captureWindows().map { $0.title.isEmpty ? "(untitled capture window #\($0.index))" : $0.title }
    }

    /// Makes the capture's window Xcode's main window and brings Xcode to the front. The server
    /// keeps one capture open at a time (xcode_open closes the others), since a capture window
    /// in the Performance view can't be told apart from another by its title.
    func focus(_ capture: String?) async throws {
        let windows = await captureWindows()
        let title = try capture.map { URL(fileURLWithPath: try paths.capture($0)).lastPathComponent }
        let target = windows.first { $0.title == title } ?? (windows.count == 1 ? windows[0] : nil)
        guard let target else {
            throw ToolError(windows.isEmpty ? "no capture is open in Xcode: call xcode_open first"
                            : "\(windows.count) captures are open in Xcode; xcode_open the one you want (it closes the others)")
        }
        try await ax(["raise", "#\(target.index)"])
        try await ax(["activate"])
        try await Task.sleep(for: .milliseconds(400))
    }

    /// Closes capture windows, highest index first so the remaining indices stay valid.
    func closeCaptureWindows(titled title: String? = nil) async throws -> Int {
        let windows = await captureWindows()
        let matching = title.map { t in windows.filter { $0.title == t } } ?? []
        let doomed = (matching.isEmpty ? windows : matching).sorted { $0.index > $1.index }
        for w in doomed { try await ax(["close", "#\(w.index)"]) ; try await Task.sleep(for: .milliseconds(500)) }
        return doomed.count
    }

    func xcodeUI(_ args: [String]) async throws -> String {
        let r = try await ax(args, check: false)
        return jsonText(["status": Int(r.status), "stdout": r.stdout, "stderr": r.stderr])
    }

    func xcodeOpen(_ trace: String, profile: Bool) async throws -> String {
        if profile { try await ensureProfiled(trace) }
        let title = URL(fileURLWithPath: trace).lastPathComponent
        let closed = try await closeCaptureWindows()
        let o = try await run("/usr/bin/open", ["-a", "Xcode", trace])
        guard o.ok else { throw ToolError("open failed: \(o.combined)") }
        let deadline = Date().addingTimeInterval(180)
        while await captureWindows().isEmpty {
            if Date() > deadline { throw ToolError("Xcode didn't open a window for \(title) within 3 minutes") }
            try await Task.sleep(for: .seconds(1))
        }
        try await focus(nil)
        var performance = false
        if GPUDebug.isProfiled(trace) {
            // A profiled capture opens on its Summary page with an Open Performance button.
            if (try await ax(["wait", "Shaders", "3"], check: false)).ok {
                performance = true
            } else if (try await ax(["wait", "Open Performance", "120"], check: false)).ok {
                try await ax(["press", "Open Performance"])
                performance = (try await ax(["wait", "Shaders", "120"], check: false)).ok
            }
        }
        return jsonText(["window": title, "performance_view": performance, "profiled": GPUDebug.isProfiled(trace),
                         "closed_other_captures": closed])
    }

    func xcodeShaders(_ capture: String?) async throws -> String {
        try await focus(capture)
        try await ax(["press", "Shaders"])
        var last = ""
        for _ in 0..<20 {
            let r = try await ax(["shaders"], check: false)
            if r.ok {
                let lines = r.stdout.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
                guard let header = lines.first else { break }
                let rows = lines.dropFirst().map { cells -> [String: Any] in
                    var d: [String: Any] = [:]
                    for (i, h) in header.enumerated() where i < cells.count {
                        let c = cells[i]
                        if h == "cost", c.hasSuffix("%"), let x = Double(c.dropLast()) { d["cost_pct"] = x }
                        else if h == "spilled", let n = Int(c.replacingOccurrences(of: " bytes", with: "")) { d["spilled_bytes"] = n }
                        else if let n = Int(c) { d[h] = n } else { d[h] = c }
                    }
                    return d
                }
                return jsonText(["shaders": rows])
            }
            last = r.combined
            try await Task.sleep(for: .seconds(1))
        }
        throw ToolError("couldn't read the Shaders table: \(last). Is a profiled capture open (xcode_open)?")
    }

    func xcodeCallStack(_ a: Args) async throws -> String {
        let label = try a.need("encoder_label")
        try await focus(a.string("capture"))
        // The Debug navigator holds the filter field; show it if it's hidden.
        if !(try await ax(["filter", label], check: false)).ok {
            try await ax(["press", "Navigators"])
            try await Task.sleep(for: .seconds(1))
            try await ax(["filter", label])
        }
        try await Task.sleep(for: .seconds(1))
        // The first draw or dispatch under the filtered encoders.
        var stage = a.string("stage")
        var row: Output?
        for call in stage == "kernel" ? ["[dispatch"] : stage == nil ? ["[draw", "[dispatch"] : ["[draw"] {
            let r = try await ax(["locate", call, "--contains"], check: false)
            if r.ok { row = r; if stage == nil { stage = call == "[draw" ? "fragment" : "kernel" }; break }
        }
        guard let row, let stage else {
            throw ToolError("no draw or dispatch found under encoders matching \(label) in the Debug navigator")
        }
        try await clickAt(row.stdout, count: 1)
        let function = ["fragment": "Fragment Function", "vertex": "Vertex Function", "kernel": "Kernel Function"][stage] ?? "Fragment Function"
        try await ax(["wait", function, "30"])
        try await focus(nil)
        try await clickAt(try await ax(["locate", function]).stdout, count: 2)
        // The source pane opens with a popup showing "Source Files"; switch it to Call Stack.
        var tree = ""
        for _ in 0..<20 {
            try await Task.sleep(for: .seconds(1))
            _ = try await ax(["choose", "Source Files", "Call Stack"], check: false)
            let r = try await ax(["callstack"], check: false)
            if r.ok && !r.stdout.isEmpty { tree = r.stdout; break }
        }
        guard !tree.isEmpty else { throw ToolError("the Call Stack view didn't appear for \(function) of \(label)") }
        let nodes: [[String: Any]] = tree.split(separator: "\n").map { line in
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
            var n: [String: Any] = ["depth": indent / 2, "name": parts.count > 1 ? parts[1] : parts.first ?? ""]
            if let c = parts.first, c.hasSuffix("%"), let x = Double(c.dropLast()) { n["cost_pct"] = x }
            return n
        }
        var result: [String: Any] = ["encoder_label": label, "stage": stage,
                                     "function": nodes.first?["name"] ?? NSNull(), "tree": nodes]
        if a.bool("save_source") ?? false {
            let fn = (nodes.first?["name"] as? String ?? "shader").replacingOccurrences(of: "/", with: "_")
            let out = paths.work.appendingPathComponent("\(fn).metal").path
            if (try await ax(["source", out], check: false)).ok { result["source_path"] = out }
        }
        return jsonText(result)
    }

    private func clickAt(_ xy: String, count: Int) async throws {
        let p = xy.split(separator: " ").map(String.init)
        guard p.count == 2 else { throw ToolError("bad position \(xy)") }
        try await ax(["click", p[0], p[1].trimmingCharacters(in: .whitespacesAndNewlines), "\(count)"])
        try await Task.sleep(for: .milliseconds(800))
    }

    func xcodeClose(_ capture: String?) async throws -> String {
        let title = try capture.map { URL(fileURLWithPath: try paths.capture($0)).lastPathComponent }
        let n = try await closeCaptureWindows(titled: title)
        try await Task.sleep(for: .seconds(1))
        return jsonText(["closed_windows": n, "still_open": await openCaptureWindows()])
    }
}

func xcodeIsRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "Xcode"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}
