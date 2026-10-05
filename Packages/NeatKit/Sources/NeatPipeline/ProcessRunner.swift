import Foundation
import NeatCore

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }
}

public enum ProcessError: Error, Sendable {
    case launchFailed(String)
    case failed(command: String, status: Int32, stderr: String)
    case timedOut(command: String)
}

/// Runs an external binary and waits for it.
///
/// Errors carry the tool's own stderr — a stage that swallows why `yt-dlp`
/// refused is a stage that cannot be debugged six months from now.
public struct ProcessRunner: Sendable {
    public init() {}

    public func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        timeout: Duration = .seconds(300)
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed("\(executable): \(error.localizedDescription)")
        }

        // Drain both pipes concurrently: a full pipe buffer deadlocks the child.
        async let stdoutData = Self.readAll(out.fileHandleForReading)
        async let stderrData = Self.readAll(err.fileHandleForReading)

        let killer = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }

        let collected = await (try? stdoutData, try? stderrData)
        process.waitUntilExit()
        killer.cancel()

        let result = ProcessResult(
            status: process.terminationStatus,
            stdout: collected.0 ?? Data(),
            stderr: String(decoding: collected.1 ?? Data(), as: UTF8.self))

        if process.terminationReason == .uncaughtSignal, process.terminationStatus != 0 {
            throw ProcessError.timedOut(command: "\(executable) \(arguments.joined(separator: " "))")
        }
        return result
    }

    /// Runs and throws unless the tool exited cleanly.
    @discardableResult
    public func runChecked(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        timeout: Duration = .seconds(300)
    ) async throws -> ProcessResult {
        let result = try await run(executable, arguments, workingDirectory: workingDirectory, timeout: timeout)
        guard result.succeeded else {
            throw ProcessError.failed(
                command: "\(URL(filePath: executable).lastPathComponent) \(arguments.joined(separator: " "))",
                status: result.status,
                stderr: String(result.stderr.suffix(2000)))
        }
        return result
    }

    static func readAll(_ handle: FileHandle) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try handle.readToEnd() ?? Data()
        }.value
    }
}
