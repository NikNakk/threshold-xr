import AppKit
import Darwin
import Foundation

/// How a launched process ended.
public enum ProcessExit: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    /// The process was not our child (opened through Launch Services), so
    /// macOS does not report its exit status.
    case unknown

    /// Signals that indicate a crash rather than a requested stop.
    public var isCrash: Bool {
        guard case let .signaled(signal) = self else { return false }
        return [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP, SIGSYS].contains(signal)
    }

    public var description: String {
        switch self {
        case let .exited(code): return "exit status \(code)"
        case let .signaled(signal):
            let name = String(cString: strsignal(signal))
            return "signal \(signal) (\(name))"
        case .unknown: return "exit status not available"
        }
    }
}

/// A process started by a launcher.
public protocol LaunchedProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    /// The log file receiving the process's output, if it is captured.
    var logURL: URL? { get }
    /// Waits for the process to end.
    func waitForExit() async -> ProcessExit
    /// Asks the process to quit (SIGTERM, or a normal app termination).
    func requestStop()
    /// Forces it to quit (SIGKILL).
    func forceStop()
}

public enum LaunchError: Error, LocalizedError, Sendable, Equatable {
    case blocked(String)
    case failedToStart(String)

    public var errorDescription: String? {
        switch self {
        case let .blocked(message): return message
        case let .failedToStart(message): return message
        }
    }
}

/// Starts launch targets. The application launcher boundary: guest-framework
/// apps (threshold-runtime) and the Windows runner will be further
/// implementations of this protocol.
public protocol ApplicationLaunching: Sendable {
    func launch(_ target: LaunchTarget, logDirectory: URL) async throws -> any LaunchedProcess
}

/// Chooses the launcher for a target's kind.
public struct DirectLauncher: ApplicationLaunching {
    public var environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func launch(_ target: LaunchTarget, logDirectory: URL) async throws -> any LaunchedProcess {
        let merged = environment.merging(target.environment) { _, override in override }
        switch target.kind {
        case .executable:
            return try ExecutableProcess.start(target, environment: merged, logDirectory: logDirectory)
        case .appBundle:
            return try await BundleProcess.open(target, environment: merged)
        }
    }
}

// MARK: Executables

/// A child process whose output goes straight to a log file. Writing to a
/// file rather than a pipe means the app keeps running, and keeps logging,
/// after Threshold XR quits.
public final class ExecutableProcess: LaunchedProcess, @unchecked Sendable {
    private let process: Process
    private let exit = ExitBox()
    public let logURL: URL?

    public var pid: Int32 { process.processIdentifier }

    private init(process: Process, logURL: URL) {
        self.process = process
        self.logURL = logURL
    }

    static func start(_ target: LaunchTarget, environment: [String: String], logDirectory: URL) throws -> ExecutableProcess {
        let logURL = try LaunchLog.create(in: logDirectory, target: target, environment: target.environment)
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            throw LaunchError.failedToStart("Could not open the launch log at \(logURL.path).")
        }
        handle.seekToEndOfFile()

        let process = Process()
        process.executableURL = target.url
        process.arguments = target.arguments
        process.environment = environment
        process.currentDirectoryURL = target.url.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle

        let launched = ExecutableProcess(process: process, logURL: logURL)
        process.terminationHandler = { [exit = launched.exit] finished in
            try? handle.close()
            let result: ProcessExit = finished.terminationReason == .uncaughtSignal
                ? .signaled(finished.terminationStatus)
                : .exited(finished.terminationStatus)
            exit.finish(result)
        }
        do {
            try process.run()
        } catch {
            try? handle.close()
            throw LaunchError.failedToStart("Could not start \(target.title): \(error.localizedDescription)")
        }
        return launched
    }

    public func waitForExit() async -> ProcessExit { await exit.wait() }

    public func requestStop() {
        if process.isRunning { process.terminate() }
    }

    public func forceStop() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}

// MARK: App bundles

/// An application opened through Launch Services, like SwiftXR Shell does.
/// Its exit is observed with a kqueue process source.
public final class BundleProcess: LaunchedProcess, @unchecked Sendable {
    private let application: NSRunningApplication
    private let exit = ExitBox()
    private var source: DispatchSourceProcess?
    public let logURL: URL? = nil

    public var pid: Int32 { application.processIdentifier }

    private init(application: NSRunningApplication) {
        self.application = application
        let source = DispatchSource.makeProcessSource(identifier: application.processIdentifier, eventMask: .exit, queue: .global())
        source.setEventHandler { [exit] in exit.finish(.unknown) }
        source.resume()
        self.source = source
        // The app may have exited before the source was armed.
        if application.isTerminated || Darwin.kill(application.processIdentifier, 0) != 0 {
            exit.finish(.unknown)
        }
    }

    deinit { source?.cancel() }

    static func open(_ target: LaunchTarget, environment: [String: String]) async throws -> BundleProcess {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = target.arguments
        configuration.environment = environment
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        do {
            let application = try await NSWorkspace.shared.openApplication(at: target.url, configuration: configuration)
            return BundleProcess(application: application)
        } catch {
            throw LaunchError.failedToStart("Could not open \(target.title): \(error.localizedDescription)")
        }
    }

    public func waitForExit() async -> ProcessExit { await exit.wait() }
    public func requestStop() { _ = application.terminate() }
    public func forceStop() { _ = application.forceTerminate() }
}

/// Delivers one exit result to any number of waiters.
final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ProcessExit?
    private var waiters: [CheckedContinuation<ProcessExit, Never>] = []

    func finish(_ value: ProcessExit) {
        let toResume: [CheckedContinuation<ProcessExit, Never>] = lock.withLock {
            guard result == nil else { return [] }
            result = value
            defer { waiters.removeAll() }
            return waiters
        }
        toResume.forEach { $0.resume(returning: value) }
    }

    func wait() async -> ProcessExit {
        await withCheckedContinuation { continuation in
            let ready: ProcessExit? = lock.withLock {
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

// MARK: Logs and crash reports

public enum LaunchLog {
    /// `~/Library/Logs/Threshold XR/Launches`.
    public static func defaultDirectory(home: URL) -> URL {
        home.appending(path: "Library/Logs/Threshold XR/Launches")
    }

    static func create(in directory: URL, target: LaunchTarget, environment: [String: String], now: Date = Date()) throws -> URL {
        let folder = directory.appending(path: sanitized(target.id))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = folder.appending(path: "\(formatter.string(from: now)).log")
        var header = "# Threshold XR launch of \(target.title) at \(now.formatted(.iso8601))\n"
        header += "# \(([target.url.path] + target.arguments).joined(separator: " "))\n"
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            header += "# env \(key)=\(value)\n"
        }
        try Data(header.utf8).write(to: url)
        return url
    }

    static func sanitized(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "app" : cleaned
    }
}

/// Finds macOS crash reports (`.ips`) written for a process after a time.
public struct CrashReportFinder: Sendable {
    public var directories: [URL]

    public init(home: URL) {
        directories = [home.appending(path: "Library/Logs/DiagnosticReports")]
    }

    public init(directories: [URL]) {
        self.directories = directories
    }

    public func report(forProcess name: String, since date: Date) -> URL? {
        let prefix = name + "-"
        return directories
            .flatMap(FileProbe.directoryContents)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { url in FileProbe.modificationDate(url).map { (url, $0) } }
            .filter { $0.1 >= date.addingTimeInterval(-1) }
            .max { $0.1 < $1.1 }?
            .0
    }
}
