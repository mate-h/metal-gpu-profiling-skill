import Foundation
import MCP

/// Output of a finished child process.
struct Output: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool

    var ok: Bool { status == 0 && !timedOut }
    /// stdout and stderr, trimmed, for error messages.
    var combined: String {
        [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct ToolError: Error, CustomStringConvertible {
    var description: String
    init(_ s: String) { description = s }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ p: Process) { process = p }
}

/// Runs a program to completion. stdout and stderr go to temporary files rather than pipes, so a
/// chatty child can't block on a full pipe, and never to this process's stdout, which is the MCP
/// channel.
func run(
    _ executable: String, _ arguments: [String], env: [String: String] = [:], cwd: String? = nil,
    timeout: Double = 600
) async throws -> Output {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("metal-debug-mcp-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let outURL = dir.appendingPathComponent("out"), errURL = dir.appendingPathComponent("err")
    fm.createFile(atPath: outURL.path, contents: nil)
    fm.createFile(atPath: errURL.path, contents: nil)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = try FileHandle(forWritingTo: outURL)
    p.standardError = try FileHandle(forWritingTo: errURL)

    let box = ProcessBox(p)
    let timer = Task {
        try await Task.sleep(for: .seconds(timeout))
        box.process.terminate()
        return true
    }
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        p.terminationHandler = { _ in c.resume() }
        do { try p.run() } catch { c.resume(throwing: error) }
    }
    timer.cancel()
    let timedOut = (try? await timer.value) ?? false
    let read = { (u: URL) in String(decoding: (try? Data(contentsOf: u)) ?? Data(), as: UTF8.self) }
    return Output(status: p.terminationStatus, stdout: read(outURL), stderr: read(errURL), timedOut: timedOut)
}

/// Runs `body` while sending a progress notification every 10 s, when the client asked for
/// progress. Saving a trace or replaying a capture can take minutes; the notifications show that
/// the call is alive.
func withHeartbeat<T: Sendable>(
    _ server: Server, _ token: ProgressToken?, _ what: String, _ body: () async throws -> T
) async throws -> T {
    guard let token else { return try await body() }
    let beat = Task {
        var elapsed = 0.0
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(10))
            elapsed += 10
            try? await server.notify(ProgressNotification.message(
                .init(progressToken: token, progress: elapsed, message: "\(what): \(Int(elapsed)) s")))
        }
    }
    defer { beat.cancel() }
    return try await body()
}

/// One GPU job at a time. Captures, replays, xctrace recordings and Xcode GUI driving disturb each
/// other: concurrent recordings corrupt each other, and a profiled capture being driven in Xcode
/// hung xctrace saves and skewed its timings.
actor GPUGate {
    private var holder: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func exclusive<T: Sendable>(_ what: String, _ body: @Sendable () async throws -> T) async throws -> T {
        while holder != nil { await withCheckedContinuation { waiters.append($0) } }
        holder = what
        defer {
            holder = nil
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    var current: String? { holder }
}
