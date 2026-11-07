import Foundation

/// The result of running an external command.
public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public var timedOut: Bool

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }

    /// Combined output, for diagnostics.
    public var combinedOutput: String {
        [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public enum CommandRunnerError: Error, LocalizedError, Sendable, Equatable {
    case launchFailed(executable: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(executable, reason):
            return "Could not run \(executable): \(reason)"
        }
    }
}

/// Runs external commands. Abstracted so service control and discovery can be
/// tested without touching launchd.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}

extension CommandRunning {
    public func run(_ executable: String, _ arguments: String..., timeout: TimeInterval = 10) async throws -> CommandResult {
        try await run(executable, arguments: arguments, timeout: timeout)
    }
}

/// Runs commands with `Process`, collecting output and enforcing a timeout.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let collector = OutputCollector()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                collector.appendOut(handle.availableData)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                collector.appendErr(handle.availableData)
            }

            let box = ProcessBox(process)

            process.terminationHandler = { finished in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(stdout.fileHandleForReading.readDataToEndOfFile())
                collector.appendErr(stderr.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: collector.result(exitCode: finished.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CommandRunnerError.launchFailed(
                    executable: executable,
                    reason: error.localizedDescription
                ))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard box.process.isRunning else { return }
                collector.markTimedOut()
                box.process.terminate()
            }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var timedOut = false

    func appendOut(_ data: Data) { lock.withLock { out.append(data) } }
    func appendErr(_ data: Data) { lock.withLock { err.append(data) } }
    func markTimedOut() { lock.withLock { timedOut = true } }

    func result(exitCode: Int32) -> CommandResult {
        lock.withLock {
            CommandResult(
                exitCode: exitCode,
                standardOutput: String(decoding: out, as: UTF8.self),
                standardError: String(decoding: err, as: UTF8.self),
                timedOut: timedOut
            )
        }
    }
}
