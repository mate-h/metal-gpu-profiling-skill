import Foundation

/// `/usr/bin/gpudebug` (macOS 27.2+): replays a .gputrace pass by pass. Each call is a one-shot
/// session (`--oneshot`), so each call pays the profile load (~5 s on a small capture).
enum GPUDebug {
    static let exe = "/usr/bin/gpudebug"

    /// Runs `commands` against `trace` with `--json` and returns every JSON value printed, in
    /// order. `go` prints the node it lands on, `list` its children, `info` its details.
    static func json(_ trace: String, _ commands: [String], timeout: Double = 900) async throws -> [Any] {
        let r = try await run(exe, ["--oneshot", "-q", "--json", "-t", trace] + commands.flatMap { ["-c", $0] },
                              timeout: timeout)
        if r.timedOut { throw ToolError("gpudebug timed out after \(Int(timeout)) s") }
        let values = splitJSON(r.stdout.replacingOccurrences(of: "\r", with: "\n"))
        if values.isEmpty {
            throw ToolError("gpudebug printed no JSON (exit \(r.status)):\n\(String(r.combined.suffix(2000)))")
        }
        for v in values {
            if let d = v as? [String: Any], d["success"] as? Bool == false {
                throw ToolError("gpudebug: \(d["notification"] ?? d["error"] ?? d)")
            }
            if let d = v as? [String: Any], let e = d["error"] { throw ToolError("gpudebug: \(e)") }
        }
        return values
    }

    /// Runs the profiling replay and embeds the result in the trace, which Xcode then opens
    /// straight into its Performance view.
    static func profile(_ trace: String) async throws -> [Any] {
        try await json(trace, ["profile run --exec serial --gpu-state high --embed"])
    }

    static func isProfiled(_ trace: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: trace)) ?? []
        return names.contains { $0.hasSuffix(".gpuprofiler_raw") }
    }

    /// The top-level JSON objects and arrays in `text`, skipping anything else (progress lines).
    static func splitJSON(_ text: String) -> [Any] {
        var out: [Any] = []
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "{") || bytes[i] == UInt8(ascii: "[") else { i += 1; continue }
            var depth = 0, inString = false, escaped = false, j = i
            while j < bytes.count {
                let c = bytes[j]
                if inString {
                    if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true }
                    else if c == UInt8(ascii: "\"") { inString = false }
                } else if c == UInt8(ascii: "\"") { inString = true }
                else if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
                else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { break }
                }
                j += 1
            }
            if j < bytes.count, let v = try? JSONSerialization.jsonObject(with: Data(bytes[i...j])) {
                out.append(v); i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    /// A `list` result's rows as dictionaries: `id` (the node name to `go` to or `info`), plus
    /// the row's values under `columns` (extra values get `col<n>`).
    static func rows(_ listing: Any?, columns: [String]) -> [[String: Any]] {
        guard let d = listing as? [String: Any], let children = d["children"] as? [[String: Any]] else { return [] }
        return children.map { c in
            var row: [String: Any] = ["id": c["name"] ?? ""]
            for (k, v) in ((c["values"] as? [Any]) ?? []).enumerated() {
                let key = k < columns.count ? columns[k] : "col\(k)"
                row[key] = plain(v)
            }
            return row
        }
    }

    /// `{"type": "percentage", "value": 14.2}` → 14.2; `"2.2349 ms"` → 2.2349; null → NSNull.
    static func plain(_ v: Any) -> Any {
        guard let d = v as? [String: Any], let value = d["value"] else { return NSNull() }
        if let s = value as? String {
            if s.hasSuffix(" ms"), let x = Double(s.dropLast(3)) { return x }
            if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 { return String(s.dropFirst().dropLast()) }
            if let n = Int(s) { return n }
            return s
        }
        return value
    }

    /// `info` details with snake_case keys and units in the name: "Temp registers": "17" →
    /// temp_registers: 17, "F32 Limiter": "38.9%" → f32_limiter_pct: 38.9, "Duration":
    /// "0.5950 ms" → duration_ms: 0.595. Other strings stay.
    static func plainInfo(_ d: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in d {
            var key = snake(k), value: Any = v
            if let s = v as? String {
                if s.hasSuffix("%"), let x = Double(s.dropLast()) { value = x; key += "_pct" }
                else if s.hasSuffix(" ms"), let x = Double(s.dropLast(3)) { value = x; key += "_ms" }
                else if let n = Int(s) { value = n }
                else if let x = Double(s) { value = x }
            }
            out[key] = value
        }
        return out
    }

    static func snake(_ s: String) -> String {
        var out = "", sep = false
        for c in s.lowercased() {
            if c.isLetter || c.isNumber { if sep && !out.isEmpty { out += "_" }; out.append(c); sep = false }
            else { sep = true }
        }
        return out
    }

    /// The label without Xcode's " (n)" repeat suffix: "noise_pass (4)" → "noise_pass".
    static func baseLabel(_ label: String) -> String {
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "("), open > label.startIndex,
              label[label.index(before: open)] == " ",
              Int(label[label.index(after: open)..<label.index(before: label.endIndex)]) != nil else { return label }
        return String(label[..<label.index(before: open)])
    }
}

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted(), n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

func round4(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }
