import AppKit
import Darwin
import Foundation
import SwiftXR
import ThresholdCore

enum ExternalOpenXRLauncherError: Error, LocalizedError {
    case alreadyLaunching
    case blocked(String)
    case applicationNotFound(String)
    case executableNotExecutable(String)
    case shellClientNotFound
    case openXRClientDidNotAppear(String)
    case launchedApplicationExited(String)
    case executableFailed(title: String, status: Int32, detail: String)
    case couldNotTerminate(String)

    var errorDescription: String? {
        switch self {
        case .alreadyLaunching:
            return "An external OpenXR application is already running"
        case let .blocked(message):
            return message
        case let .applicationNotFound(path):
            return "External application was not found at \(path)"
        case let .executableNotExecutable(path):
            return "External application is not executable: \(path)"
        case .shellClientNotFound:
            return "Could not identify SwiftXR Shell in Monado's client list"
        case let .openXRClientDidNotAppear(title):
            return "\(title) launched, but no new Monado OpenXR client appeared"
        case let .launchedApplicationExited(title):
            return "\(title) exited before creating an OpenXR client"
        case let .executableFailed(title, status, detail):
            return "\(title) could not start (exit \(status)).\n\(detail)"
        case let .couldNotTerminate(title):
            return "Could not terminate \(title)"
        }
    }
}

@MainActor
final class ExternalOpenXRLauncher {
    var onSwitchedToApplication: ((XRMonadoClient) -> Void)?
    var onReturnedToShell: (() -> Void)?
    var onError: ((Error) -> Void)?

    private var monado: XRMonadoRuntimeControl?
    private var monitorTask: Task<Void, Never>?
    private var terminationFallbackTask: Task<Void, Never>?

    private var baselineClientIDs = Set<UInt32>()
    private var shellClientID: UInt32?
    private var targetClientID: UInt32?
    private var targetSessionWasActive = false
    private var launchDeadline = Date.distantPast
    private var stopGracePeriod: TimeInterval = 2
    private var stopRequested = false
    private var currentApplication: ShellApplication?

    /// Starts processes the same way Threshold XR does (ThresholdCore), with
    /// per-launch logs in ~/Library/Logs/Threshold XR/Launches.
    private let launcher: any ApplicationLaunching
    private let logDirectory: URL
    private var launchTask: Task<Void, Never>?
    private var launched: (any LaunchedProcess)?
    private var exit: ProcessExit?

    init(
        launcher: any ApplicationLaunching = DirectLauncher(),
        logDirectory: URL = LaunchLog.defaultDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    ) {
        self.launcher = launcher
        self.logDirectory = logDirectory
    }

    var isRunningExternalApplication: Bool {
        currentApplication != nil
    }

    var currentApplicationTitle: String? {
        currentApplication?.title
    }

    func launch(_ application: ShellApplication, external: ExternalOpenXRApplication) throws {
        guard currentApplication == nil else {
            throw ExternalOpenXRLauncherError.alreadyLaunching
        }

        let issues = LaunchPreflight.check(external.target, monado: nil, alreadyRunning: false)
        if let blocking = issues.first(where: { $0.severity == .blocking }) {
            throw ExternalOpenXRLauncherError.blocked(blocking.message)
        }

        let monado = try monado ?? XRMonadoRuntimeControl()
        self.monado = monado

        let clients = try monado.refreshClients()
        guard let shellClient = clients.first(where: {
            $0.state.contains(.primaryApplication)
        }) ?? clients.first(where: {
            $0.name.caseInsensitiveCompare("SwiftXR Shell") == .orderedSame
        }) else {
            throw ExternalOpenXRLauncherError.shellClientNotFound
        }

        baselineClientIDs = Set(clients.map(\.id))
        shellClientID = shellClient.id
        targetClientID = nil
        targetSessionWasActive = false
        currentApplication = application
        stopRequested = false
        stopGracePeriod = external.stopGracePeriod
        launchDeadline = Date().addingTimeInterval(external.openXRClientTimeout)

        let target = external.target
        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let process = try await self.launcher.launch(target, logDirectory: self.logDirectory)
                guard self.currentApplication?.id == application.id, self.launchTask != nil else {
                    process.requestStop()
                    return
                }
                self.launched = process
                if let log = process.logURL { print("[shell] \(application.title) log: \(log.path)") }
                Task { @MainActor [weak self] in
                    let exit = await process.waitForExit()
                    guard let self, self.launched === process else { return }
                    self.exit = exit
                    print("[shell] \(application.title) ended: \(exit.description)")
                }
                if self.stopRequested {
                    process.requestStop()
                    self.scheduleForcedTermination()
                }
                self.startMonitoring()
            } catch {
                guard self.currentApplication?.id == application.id else { return }
                self.fail(error)
            }
        }
    }

    func terminateForegroundApplication() throws {
        guard currentApplication != nil else {
            throw ExternalOpenXRLauncherError.couldNotTerminate("OpenXR application")
        }
        stopRequested = true
        // Still starting: the launch task stops it once it has a process.
        guard let launched, exit == nil else { return }
        launched.requestStop()
        scheduleForcedTermination()
    }

    func shutdown() {
        launchTask?.cancel()
        monitorTask?.cancel()
        monitorTask = nil
        terminationFallbackTask?.cancel()
        terminationFallbackTask = nil
        clearLaunchState()
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.currentApplication != nil else { return }
                self.pollMonadoClients()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func scheduleForcedTermination() {
        terminationFallbackTask?.cancel()
        terminationFallbackTask = Task { @MainActor [weak self] in
            let grace = self?.stopGracePeriod ?? 2
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard let self, !Task.isCancelled, self.currentApplication != nil else { return }

            if let launched = self.launched, self.exit == nil {
                print("[shell] launched application ignored the stop request; forcing it")
                launched.forceStop()
            }
        }
    }

    private func pollMonadoClients() {
        guard
            let monado,
            let application = currentApplication,
            case let .external(external) = application.kind
        else { return }

        do {
            let clients = try monado.refreshClients()

            if let targetClientID {
                guard let target = clients.first(where: { $0.id == targetClientID }) else {
                    try restoreShell(using: clients)
                    return
                }

                if target.state.contains(.sessionActive) {
                    targetSessionWasActive = true
                } else if targetSessionWasActive {
                    // Some hosts (notably browsers) can keep their OpenXR
                    // client/instance alive after an immersive session ends.
                    // Restore the Shell when presentation stops rather than
                    // waiting for the client process to disconnect.
                    try restoreShell(using: clients)
                }
                return
            }

            let candidates = clients.filter {
                !baselineClientIDs.contains($0.id) && !$0.state.contains(.sessionOverlay)
            }

            if let target = chooseTarget(
                from: candidates,
                expectedApplicationName: external.openXRApplicationName
            ) {
                try monado.setPrimary(clientID: target.id)
                try monado.setFocused(clientID: target.id)
                targetClientID = target.id
                targetSessionWasActive = target.state.contains(.sessionActive)
                print("[shell] handed HMD to Monado client \(target.id): \(target.name)")
                onSwitchedToApplication?(target)
                return
            }

            if launchedApplicationHasExited, stopRequested {
                // Stopped from Home before it took the HMD: not an error.
                print("[shell] \(application.title) stopped before creating an OpenXR client")
                finishWithoutClient()
                return
            }

            if launchedApplicationHasExited {
                switch exit {
                case let .exited(status) where status != 0:
                    throw ExternalOpenXRLauncherError.executableFailed(
                        title: application.title, status: status, detail: logSummary
                    )
                case let .signaled(signal):
                    throw ExternalOpenXRLauncherError.executableFailed(
                        title: application.title, status: 128 + signal, detail: logSummary
                    )
                default:
                    throw ExternalOpenXRLauncherError.launchedApplicationExited(application.title)
                }
            }

            if Date() >= launchDeadline {
                throw ExternalOpenXRLauncherError.openXRClientDidNotAppear(application.title)
            }
        } catch {
            fail(error)
        }
    }

    private func chooseTarget(
        from candidates: [XRMonadoClient],
        expectedApplicationName: String?
    ) -> XRMonadoClient? {
        guard !candidates.isEmpty else { return nil }

        if let expectedApplicationName, !expectedApplicationName.isEmpty {
            if let exact = candidates.first(where: {
                $0.name.caseInsensitiveCompare(expectedApplicationName) == .orderedSame
            }) {
                return exact
            }

            if let partial = candidates.first(where: {
                $0.name.localizedCaseInsensitiveContains(expectedApplicationName)
                    || expectedApplicationName.localizedCaseInsensitiveContains($0.name)
            }) {
                return partial
            }
        }

        return candidates.sorted { lhs, rhs in
            let lhsActive = lhs.state.contains(.sessionActive)
            let rhsActive = rhs.state.contains(.sessionActive)
            if lhsActive != rhsActive {
                return lhsActive && !rhsActive
            }
            return lhs.id < rhs.id
        }.first
    }

    private func restoreShell(using clients: [XRMonadoClient]) throws {
        guard let shellClientID else {
            throw ExternalOpenXRLauncherError.shellClientNotFound
        }
        guard clients.contains(where: { $0.id == shellClientID }) else {
            throw ExternalOpenXRLauncherError.shellClientNotFound
        }
        guard let monado else { return }

        try monado.setPrimary(clientID: shellClientID)
        try monado.setFocused(clientID: shellClientID)
        print("[shell] external OpenXR client exited; restored SwiftXR Shell")

        monitorTask?.cancel()
        monitorTask = nil
        terminationFallbackTask?.cancel()
        terminationFallbackTask = nil
        clearLaunchState()
        onReturnedToShell?()
    }

    private func finishWithoutClient() {
        monitorTask?.cancel()
        monitorTask = nil
        terminationFallbackTask?.cancel()
        terminationFallbackTask = nil
        clearLaunchState()
        onReturnedToShell?()
    }

    private func fail(_ error: Error) {
        if let monado, let shellClientID {
            if let clients = try? monado.refreshClients(),
               clients.contains(where: { $0.id == shellClientID }) {
                try? monado.setPrimary(clientID: shellClientID)
                try? monado.setFocused(clientID: shellClientID)
            }
        }

        monitorTask?.cancel()
        monitorTask = nil
        terminationFallbackTask?.cancel()
        terminationFallbackTask = nil
        clearLaunchState()
        onError?(error)
    }

    private var launchedApplicationHasExited: Bool {
        launched != nil && exit != nil
    }

    /// The last lines of the launch log, for an actionable start-up failure.
    private var logSummary: String {
        guard let url = launched?.logURL else { return "" }
        return LaunchOutputTail.summary(ofLogAt: url)
    }

    private func clearLaunchState() {
        baselineClientIDs.removeAll()
        shellClientID = nil
        targetClientID = nil
        targetSessionWasActive = false
        currentApplication = nil
        launchTask = nil
        launched = nil
        exit = nil
        launchDeadline = .distantPast
        stopGracePeriod = 2
        stopRequested = false
    }
}

/// Bounded, thread-safe output capture; a child can emit more than a pipe's
/// capacity without blocking and its actionable failure survives in Home.
final class LaunchOutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data)
        if bytes.count > 16_384 { bytes = Data(bytes.suffix(16_384)) }
    }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        let lines = String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline)
        return lines.suffix(4).joined(separator: "\n")
    }

    /// The summary of a log file's last 16 KB, skipping Threshold's `#` header lines.
    static func summary(ofLogAt url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let tail = LaunchOutputTail()
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let body = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("# ") }.joined(separator: "\n")
        tail.append(Data(body.utf8))
        return tail.summary
    }
}
