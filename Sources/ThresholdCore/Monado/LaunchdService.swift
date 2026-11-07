import Foundation

/// What launchd reports for a job, parsed from `launchctl print`.
public struct LaunchdJobStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// launchd has no job with this label in the user's GUI domain.
        case notLoaded
        /// Loaded and idle (for Monado: waiting for on-demand activation).
        case loadedIdle
        case running(pid: Int32)
        /// launchd reports another state (for example "spawn scheduled").
        case other(String)
    }

    public var state: State
    public var plistPath: String?
    public var program: String?
    public var runs: Int?
    public var lastExitCode: String?
    public var lastTerminatingSignal: String?
    public var environment: [String: String]
    public var machServices: [String]

    public init(
        state: State,
        plistPath: String? = nil,
        program: String? = nil,
        runs: Int? = nil,
        lastExitCode: String? = nil,
        lastTerminatingSignal: String? = nil,
        environment: [String: String] = [:],
        machServices: [String] = []
    ) {
        self.state = state
        self.plistPath = plistPath
        self.program = program
        self.runs = runs
        self.lastExitCode = lastExitCode
        self.lastTerminatingSignal = lastTerminatingSignal
        self.environment = environment
        self.machServices = machServices
    }

    public static let notLoaded = LaunchdJobStatus(state: .notLoaded)

    public var isLoaded: Bool { state != .notLoaded }
    public var pid: Int32? { if case let .running(pid) = state { pid } else { nil } }
    public var isRunning: Bool { pid != nil }

    /// True when the last run ended abnormally (non-zero exit or a signal
    /// other than an orderly SIGTERM).
    public var lastExitWasAbnormal: Bool {
        if let signal = lastTerminatingSignal, !signal.localizedCaseInsensitiveContains("terminated") {
            return true
        }
        guard let code = lastExitCode?.trimmingCharacters(in: .whitespaces), let value = Int(code) else {
            return false
        }
        return value != 0
    }

    /// Parses the human-readable output of `launchctl print gui/<uid>/<label>`.
    ///
    /// The format is not a stable API, so parsing is deliberately tolerant:
    /// unknown lines are ignored and missing fields stay `nil`.
    public static func parse(launchctlPrint output: String) -> LaunchdJobStatus {
        var status = LaunchdJobStatus(state: .other("unknown"))
        var stateText: String?
        var pid: Int32?
        // Names of the nested `name = {` blocks enclosing the current line.
        var blocks: [String] = []

        for rawLine in output.split(separator: "\n") {
            let text = rawLine.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }

            if text.hasSuffix("= {") {
                let name = text.dropLast(3).trimmingCharacters(in: .whitespaces)
                if blocks.count == 2, blocks[1] == "endpoints" {
                    status.machServices.append(name.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                }
                blocks.append(name)
                continue
            }
            if text == "}" {
                _ = blocks.popLast()
                continue
            }

            // Variables the running job was given (not "inherited environment").
            if blocks.count == 2, blocks[1] == "environment", let range = text.range(of: " => ") {
                status.environment[String(text[..<range.lowerBound])] = String(text[range.upperBound...])
                continue
            }

            // Top-level fields of the job dictionary.
            guard blocks.count == 1, let range = text.range(of: " = ") else { continue }
            let key = String(text[..<range.lowerBound])
            let value = String(text[range.upperBound...])
            switch key {
            case "state": stateText = value
            case "pid": pid = Int32(value)
            case "path": status.plistPath = value
            case "program": status.program = value
            case "runs": status.runs = Int(value)
            case "last exit code": status.lastExitCode = value
            case "last terminating signal": status.lastTerminatingSignal = value
            default: break
            }
        }

        switch (stateText, pid) {
        case let (_, pid?) where stateText == nil || stateText == "running":
            status.state = .running(pid: pid)
        case ("not running"?, _), ("waiting"?, _):
            status.state = .loadedIdle
        case let (text?, _):
            status.state = .other(text)
        case (nil, nil):
            // Seen briefly while launchd tears a job down after SIGTERM: the
            // job is loaded but reports no state line and has no process.
            status.state = .loadedIdle
        default:
            break
        }
        return status
    }
}

public enum LaunchdServiceError: Error, LocalizedError, Sendable, Equatable {
    case notLoaded(label: String)
    case plistMissing(path: String)
    case commandFailed(action: String, exitCode: Int32, output: String)
    case stopTimedOut(label: String, seconds: Int)

    public var errorDescription: String? {
        switch self {
        case let .notLoaded(label):
            return "The LaunchAgent \(label) is not loaded in your login session."
        case let .plistMissing(path):
            return "The LaunchAgent property list is missing: \(path)"
        case let .commandFailed(action, code, output):
            let detail = output.isEmpty ? "" : "\n\(output)"
            return "\(action) failed (launchctl exit status \(code)).\(detail)"
        case let .stopTimedOut(label, seconds):
            return "\(label) did not exit within \(seconds) seconds of SIGTERM. It may still be closing the headset; you can force it to stop."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notLoaded:
            return "Load the existing LaunchAgent, or reinstall it with monado-service-xpc-control install."
        case .plistMissing:
            return "Install the service with monado-service-xpc-control install from the Monado prefix."
        case .commandFailed:
            return "See Diagnostics for the service log."
        case .stopTimedOut:
            return "Use Force Stop only if the service is unresponsive."
        }
    }
}

/// Controls one per-user launchd job through `/bin/launchctl`.
///
/// Only user-domain operations are used, so no administrator rights are
/// needed. Nothing here edits the job's property list.
public struct LaunchdService: Sendable {
    public let label: String
    public let domain: String
    public let runner: any CommandRunning
    public var launchctl: String = "/bin/launchctl"

    public init(label: String, domain: String, runner: any CommandRunning) {
        self.label = label
        self.domain = domain
        self.runner = runner
    }

    public var target: String { "\(domain)/\(label)" }

    public func status() async throws -> LaunchdJobStatus {
        let result = try await runner.run(launchctl, arguments: ["print", target], timeout: 10)
        if result.exitCode == 113 || result.combinedOutput.contains("Could not find service") {
            return .notLoaded
        }
        guard result.succeeded else {
            throw LaunchdServiceError.commandFailed(
                action: "Reading the service status",
                exitCode: result.exitCode,
                output: result.combinedOutput
            )
        }
        return LaunchdJobStatus.parse(launchctlPrint: result.standardOutput)
    }

    /// Starts the job if it is not already running (`kickstart` without `-k`).
    public func start() async throws {
        try await perform("Starting \(label)", ["kickstart", target])
    }

    /// Kills and restarts the job (`kickstart -k`).
    public func restart() async throws {
        try await perform("Restarting \(label)", ["kickstart", "-k", target])
    }

    /// Sends SIGTERM and waits for the process to exit. launchd does not
    /// relaunch it unless a client asks for it again (on-demand activation).
    public func stop(timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.25) async throws {
        try await perform("Stopping \(label)", ["kill", "SIGTERM", target])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = try await status()
            if !current.isRunning { return }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw LaunchdServiceError.stopTimedOut(label: label, seconds: Int(timeout))
    }

    public func forceStop() async throws {
        try await perform("Force-stopping \(label)", ["kill", "SIGKILL", target])
    }

    /// Registers the job from its property list (`bootstrap`). launchd can
    /// briefly return EIO (5) while a previous instance is being torn down,
    /// so this retries, as Monado's own registration helper does.
    public func load(plist: URL, attempts: Int = 5) async throws {
        guard FileProbe.exists(plist) else { throw LaunchdServiceError.plistMissing(path: plist.path) }
        var last = CommandResult(exitCode: 0)
        for attempt in 1...max(1, attempts) {
            last = try await runner.run(launchctl, arguments: ["bootstrap", domain, plist.path], timeout: 15)
            if last.succeeded { return }
            // Already loaded (EEXIST surfaces as 17 or 37 depending on release).
            if last.combinedOutput.localizedCaseInsensitiveContains("already") { return }
            guard last.exitCode == 5, attempt < attempts else { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LaunchdServiceError.commandFailed(
            action: "Loading \(label)",
            exitCode: last.exitCode,
            output: last.combinedOutput
        )
    }

    /// Unloads the job (`bootout`). This stops a running instance.
    public func unload() async throws {
        let result = try await runner.run(launchctl, arguments: ["bootout", target], timeout: 20)
        if result.succeeded || result.exitCode == 113 || result.exitCode == 3 { return }
        throw LaunchdServiceError.commandFailed(
            action: "Unloading \(label)",
            exitCode: result.exitCode,
            output: result.combinedOutput
        )
    }

    /// Re-reads the property list: launchd only reads it at bootstrap.
    public func reload(plist: URL) async throws {
        try await unload()
        try await load(plist: plist)
    }

    /// Reads a variable from launchd's user-session environment, which GUI
    /// applications inherit (`launchctl getenv`).
    public func sessionEnvironmentValue(_ name: String) async -> String? {
        guard let result = try? await runner.run(launchctl, arguments: ["getenv", name], timeout: 5),
              result.succeeded else { return nil }
        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func perform(_ action: String, _ arguments: [String]) async throws {
        let result = try await runner.run(launchctl, arguments: arguments, timeout: 20)
        if result.succeeded { return }
        if result.exitCode == 113 || result.combinedOutput.contains("Could not find service") {
            throw LaunchdServiceError.notLoaded(label: label)
        }
        throw LaunchdServiceError.commandFailed(action: action, exitCode: result.exitCode, output: result.combinedOutput)
    }
}
