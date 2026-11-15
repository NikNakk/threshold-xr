import Darwin
import Foundation

/// An application provided by the guest-app framework (threshold-runtime): one entry of
/// `threshold-run --list --json`. Threshold XR launches it by id and knows nothing about
/// how its guest loader works (docs/design.md §6).
public struct FrameworkProfile: Sendable, Equatable, Decodable, Identifiable {
    public struct Component: Sendable, Equatable, Decodable {
        public var path: String
        public var exists: Bool
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    /// `linux` (Linux ARM64 guests such as Half-Life: Alyx) or `android` (Quest APKs).
    public var guest: String
    public var openXRApplicationName: String?
    public var systemImage: String?
    /// The profile file.
    public var path: String
    public var componentSets: [String]
    public var components: [String: Component]

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, guest, path, components
        case openXRApplicationName = "openxr_application_name"
        case systemImage = "system_image"
        case componentSets = "component_sets"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        guest = try c.decode(String.self, forKey: .guest)
        openXRApplicationName = try c.decodeIfPresent(String.self, forKey: .openXRApplicationName)
        systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage)
        path = try c.decode(String.self, forKey: .path)
        componentSets = try c.decodeIfPresent([String].self, forKey: .componentSets) ?? []
        components = try c.decodeIfPresent([String: Component].self, forKey: .components) ?? [:]
    }

    /// Components whose files are missing, as "name (path)".
    public var missingComponents: [String] {
        components.filter { !$0.value.exists }.map { "\($0.key) (\($0.value.path))" }.sorted()
    }

    /// The executable name of the guest host, which macOS uses for crash reports.
    public var hostProcessName: String? {
        components["host"].map { URL(fileURLWithPath: $0.path).lastPathComponent }
    }
}

public enum FrameworkCatalogError: Error, LocalizedError, Sendable, Equatable {
    case runnerMissing(String)
    case listFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .runnerMissing(path): return "threshold-run was not found at \(path)."
        case let .listFailed(message): return "threshold-run --list failed: \(message)"
        }
    }
}

/// Finds threshold-run and asks it which applications it provides.
public enum FrameworkCatalog {
    /// `THRESHOLD_RUNTIME/bin/threshold-run`, default `~/Code/threshold-runtime`, as discovery uses.
    public static func runner(context: DiscoveryContext) -> URL {
        let root = context.environment["THRESHOLD_RUNTIME"].map(context.expand) ?? context.workspace("threshold-runtime")
        return root.appending(path: "bin/threshold-run")
    }

    public static func decode(_ data: Data) throws -> [FrameworkProfile] {
        try JSONDecoder().decode([FrameworkProfile].self, from: data)
    }

    /// Runs `threshold-run --list --json`. It reads files only; it starts nothing.
    public static func load(context: DiscoveryContext) throws -> [FrameworkProfile] {
        let runner = runner(context: context)
        guard FileProbe.isExecutableFile(runner) else { throw FrameworkCatalogError.runnerMissing(runner.path) }
        let process = Process()
        process.executableURL = runner
        process.arguments = ["--list", "--json"]
        process.environment = context.environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FrameworkCatalogError.listFailed(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try decode(data)
    }
}

/// threshold-run's status stream (`--status-file`, one JSON object per line).
public enum FrameworkStatus {
    public struct Event: Sendable, Equatable, Decodable {
        public var event: String
        public var run: String?
        public var log: String?
        public var exitCode: Int32?
        public var signal: Int32?
        public var crashed: Bool?
        public var stoppedBy: String?
        public var problems: [String]?

        enum CodingKeys: String, CodingKey {
            case event, run, log, signal, crashed, problems
            case exitCode = "exit_code"
            case stoppedBy = "stopped_by"
        }
    }

    public static func events(at url: URL) -> [Event] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
    }

    /// The app's exit as threshold-run reported it. A crash by signal is that signal; a guest
    /// fault without one is reported as SIGABRT, so it still counts as a crash. Without an
    /// "exited" event (threshold-run itself was killed) the runner's own exit is used.
    public static func exit(from events: [Event], runnerExit: ProcessExit) -> ProcessExit {
        guard let last = events.last(where: { $0.event == "exited" }) else { return runnerExit }
        if last.crashed == true { return .signaled(last.signal ?? SIGABRT) }
        return .exited(last.exitCode ?? 0)
    }
}

/// Launches framework profiles through threshold-run with a status file next to the launch log.
public enum FrameworkLauncher {
    static func start(_ target: LaunchTarget, environment: [String: String], logDirectory: URL) throws -> FrameworkProcess {
        let folder = logDirectory.appending(path: LaunchLog.sanitized(target.id))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let status = folder.appending(path: "\(formatter.string(from: Date()))-status.jsonl")
        var runner = target
        runner.kind = .executable
        runner.arguments += ["--status-file", status.path]
        let process = try ExecutableProcess.start(runner, environment: environment, logDirectory: logDirectory)
        return FrameworkProcess(process: process, statusURL: status)
    }
}

/// threshold-run as a launched process, with its exit taken from the app's status.
public final class FrameworkProcess: LaunchedProcess, @unchecked Sendable {
    private let process: ExecutableProcess
    public let statusURL: URL

    init(process: ExecutableProcess, statusURL: URL) {
        self.process = process
        self.statusURL = statusURL
    }

    public var pid: Int32 { process.pid }
    public var logURL: URL? { process.logURL }

    /// The app's run folder, once threshold-run has started it.
    public var runURL: URL? {
        FrameworkStatus.events(at: statusURL).last(where: { $0.event == "started" })?.run.map(URL.init(fileURLWithPath:))
    }

    public func waitForExit() async -> ProcessExit {
        let runnerExit = await process.waitForExit()
        return FrameworkStatus.exit(from: FrameworkStatus.events(at: statusURL), runnerExit: runnerExit)
    }

    /// threshold-run turns SIGTERM into a stop of the app (SIGTERM, then SIGKILL after 5 s).
    public func requestStop() { process.requestStop() }
    public func forceStop() { process.forceStop() }
}
