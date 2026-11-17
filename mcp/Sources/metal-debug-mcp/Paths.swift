import Foundation

/// Where the skill's scripts live and where the server keeps captures and built helpers.
struct Paths: Sendable {
    /// The skill folder (holds `scripts/` and `references/`).
    let skill: URL
    /// The server's own folder: captures, recordings, the built `xcode_ax`.
    let work: URL

    var scripts: URL { skill.appendingPathComponent("scripts") }
    var captures: URL { work.appendingPathComponent("captures") }
    var recordings: URL { work.appendingPathComponent("recordings") }
    var xcodeAx: URL { work.appendingPathComponent("xcode_ax") }

    func script(_ name: String) -> String { scripts.appendingPathComponent(name).path }

    static func resolve() throws -> Paths {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        var skill: URL?
        if let s = env["METAL_GPU_SKILL_ROOT"] {
            skill = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        } else {
            // The binary is built inside the skill (mcp/.build/<config>/metal-debug-mcp): walk up.
            var dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
                .resolvingSymlinksInPath().deletingLastPathComponent()
            while dir.path != "/" {
                if fm.fileExists(atPath: dir.appendingPathComponent("scripts/gputrace_stats.py").path) {
                    skill = dir; break
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        guard let skill, fm.fileExists(atPath: skill.appendingPathComponent("scripts").path) else {
            throw ToolError("can't find the skill's scripts/ folder; set METAL_GPU_SKILL_ROOT")
        }
        let work = env["METAL_DEBUG_MCP_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/metal-debug-mcp")
        let paths = Paths(skill: skill, work: work)
        for d in [paths.work, paths.captures, paths.recordings] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return paths
    }

    /// Resolves a capture argument: an absolute path, `~/...`, or a name in the captures folder.
    func capture(_ arg: String) throws -> String {
        let fm = FileManager.default
        var path = (arg as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = captures.appendingPathComponent(path).path }
        if !path.hasSuffix(".gputrace"), fm.fileExists(atPath: path + ".gputrace") { path += ".gputrace" }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, path.hasSuffix(".gputrace") else {
            throw ToolError("no .gputrace at \(path)")
        }
        return path
    }

    /// Builds `scripts/xcode_ax.swift` into the work folder when the binary is missing or older
    /// than the source.
    func ensureXcodeAx() async throws -> String {
        let fm = FileManager.default
        let src = scripts.appendingPathComponent("xcode_ax.swift").path
        let mtime = { (p: String) in (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast }
        if fm.fileExists(atPath: xcodeAx.path), mtime(xcodeAx.path) >= mtime(src) { return xcodeAx.path }
        let r = try await run("/usr/bin/xcrun", ["swiftc", "-O", src, "-o", xcodeAx.path], timeout: 300)
        guard r.ok else { throw ToolError("building xcode_ax failed:\n\(r.combined)") }
        return xcodeAx.path
    }
}

func sizeOnDisk(_ path: String) -> Int64 {
    let fm = FileManager.default
    guard let e = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
    var total: Int64 = 0
    for case let u as URL in e {
        total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }
    return total
}

func megabytes(_ bytes: Int64) -> Double { (Double(bytes) / 1_048_576).rounded() }
