import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var out: String { String(lossyUTF8: stdout) }
    public var err: String { String(lossyUTF8: stderr) }
    public var succeeded: Bool { status == 0 }
}

public enum ShellError: LocalizedError {
    case launchFailed(String, underlying: String)
    case timedOut(String, seconds: TimeInterval)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let cmd, let e): "Could not launch \(cmd): \(e)"
        case .timedOut(let cmd, let s): "\(cmd) exceeded \(Int(s))s and was terminated"
        case .notFound(let cmd): "\(cmd) is not present on this host"
        }
    }
}

/// Minimal async subprocess runner.
///
/// Both pipes are drained on background queues before we wait, so a child that
/// writes more than a pipe buffer (a sysdiagnose listing, a full IORegistry
/// dump) cannot deadlock us.
public enum Shell {
    public static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30,
        stdin: Data? = nil
    ) async throws -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let environment {
            proc.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { proc.standardInput = inPipe }

        let drain = Drain()
        let queue = DispatchQueue(label: "auscult.shell.drain", attributes: .concurrent)
        queue.async { drain.setOut(outPipe.fileHandleForReading.readDataToEndOfFile()) }
        queue.async { drain.setErr(errPipe.fileHandleForReading.readDataToEndOfFile()) }

        do {
            try proc.run()
        } catch {
            throw ShellError.launchFailed(
                (executable as NSString).lastPathComponent,
                underlying: error.localizedDescription
            )
        }

        if let inPipe, let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning {
            if Date() > deadline {
                proc.terminate()
                try? await Task.sleep(nanoseconds: 300_000_000)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                throw ShellError.timedOut((executable as NSString).lastPathComponent, seconds: timeout)
            }
            if Task.isCancelled {
                proc.terminate()
                throw CancellationError()
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        // Give the drain queues a beat to publish the final chunk.
        try? await Task.sleep(nanoseconds: 60_000_000)
        return ShellResult(status: proc.terminationStatus, stdout: drain.out, stderr: drain.err)
    }

    /// Resolve a tool, preferring an explicit path, then PATH, then known locations.
    public static func locate(_ name: String, extraDirectories: [String] = []) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let dirs = extraDirectories + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Thread-safe collector for the two pipe readers.
    private final class Drain: @unchecked Sendable {
        private let lock = NSLock()
        private var _out = Data(), _err = Data()
        var out: Data { lock.withLock { _out } }
        var err: Data { lock.withLock { _err } }
        func setOut(_ d: Data) { lock.withLock { _out = d } }
        func setErr(_ d: Data) { lock.withLock { _err = d } }
    }
}

public extension String {
    /// Decode subprocess output without losing all of it to one bad byte.
    init(lossyUTF8 data: Data) {
        self = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}
