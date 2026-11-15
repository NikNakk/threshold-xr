import AppKit
import Foundation
import Observation
import OSLog
import ThresholdCore

let log = Logger(subsystem: "com.thresholdxr.app", category: "app")

/// One line in the in-app activity log shown on the Diagnostics screen.
struct ActivityEntry: Identifiable, Sendable {
    enum Level: Sendable { case info, warning, error }
    let id = UUID()
    let date = Date()
    let level: Level
    let message: String
}

/// An error shown to the user, with what to try next.
struct UserFacingError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let suggestion: String?

    init(_ title: String, _ error: Error) {
        self.title = title
        self.message = error.localizedDescription
        self.suggestion = (error as? LocalizedError)?.recoverySuggestion
    }

    init(_ title: String, message: String, suggestion: String? = nil) {
        self.title = title
        self.message = message
        self.suggestion = suggestion
    }
}

enum ServiceAction: String, Sendable {
    case start = "Starting"
    case stop = "Stopping"
    case forceStop = "Force-stopping"
    case restart = "Restarting"
    case load = "Loading"
    case reload = "Reloading"
    case query = "Querying"
}

/// UI state for the app. Business logic lives in ThresholdCore; this type
/// only schedules work and publishes results.
@MainActor
@Observable
final class AppModel {
    let preferences = AppPreferences()

    private(set) var context: DiscoveryContext
    private(set) var controller: MonadoController

    var monado: MonadoStatus?
    var components: [ComponentStatus] = []
    var isDiscoveringComponents = false
    var busyAction: ServiceAction?
    /// Set when a stop request timed out, so the UI can offer SIGKILL.
    var offerForceStop = false
    var error: UserFacingError?
    var activity: [ActivityEntry] = []

    var monadoSettings: [MonadoSettingValue] = []
    var monadoSettingsError: String?
    var lastBackup: URL?
    /// Threshold Home's catalog and threshold-runtime's applications, shared with Threshold Home.
    var applications = ApplicationCatalog()
    var shellAppsError: String? { applications.problem(.shellCatalog) }
    var frameworkProfilesError: String? { applications.problem(.framework) }

    /// Direct launches and their status.
    let launches: LaunchCoordinator
    private var lastLaunchPhases: [UUID: LaunchRecord.Phase] = [:]

    private var refreshTask: Task<Void, Never>?
    private var lastServiceState: MonadoStatus.ServiceState?

    init() {
        let context = DiscoveryContext.current(
            workspaceRoot: preferences.workspaceRoot,
            windowsRigRoot: preferences.windowsRigRoot,
            pathOverrides: preferences.pathOverrides
        )
        self.context = context
        self.controller = MonadoController(context: context, policy: Self.policy(from: preferences))
        self.launches = LaunchCoordinator(
            launcher: DirectLauncher(),
            crashFinder: CrashReportFinder(home: context.homeDirectory),
            logDirectory: LaunchLog.defaultDirectory(home: context.homeDirectory)
        )
        launches.onChange = { [weak self] record in self?.noteLaunchChange(record) }
    }

    private static func policy(from preferences: AppPreferences) -> RuntimeQueryPolicy {
        RuntimeQueryPolicy(automaticQueriesEnabled: preferences.automaticRuntimeQueries)
    }

    // MARK: Lifecycle

    func start() {
        guard refreshTask == nil else { return }
        record(.info, "Threshold XR started. Monado is managed through its existing LaunchAgent and is never stopped when this app quits.")
        Task { await discoverComponents() }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshStatus()
                // Follow launches closely while one is starting or running.
                let active = self.launches.records.contains { $0.phase.isActive }
                let interval = active ? min(1, self.preferences.refreshInterval) : self.preferences.refreshInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Rebuilds the discovery context after preferences or overrides change.
    func preferencesChanged() {
        context = DiscoveryContext.current(
            workspaceRoot: preferences.workspaceRoot,
            windowsRigRoot: preferences.windowsRigRoot,
            pathOverrides: preferences.pathOverrides
        )
        controller = MonadoController(context: context, policy: Self.policy(from: preferences))
        Task {
            await refreshStatus()
            await discoverComponents()
        }
    }

    // MARK: Status

    func refreshStatus(explicitQuery: Bool = false) async {
        let status = await controller.refresh(explicitQuery: explicitQuery)
        noteTransitions(to: status)
        if !status.isServiceRunning { offerForceStop = false }
        monado = status
        launches.observe(status)
        connectToHomeIfRunning()
        loadMonadoSettings(status: status)
    }

    func discoverComponents() async {
        isDiscoveringComponents = true
        defer { isDiscoveringComponents = false }
        let context = self.context
        let installation = monado?.installation
        // Discovery reads and scans files; keep it off the main thread.
        components = await Task.detached(priority: .userInitiated) {
            ComponentDiscovery(context: context).discoverAll(monado: installation)
        }.value
        // threshold-run --list reads profiles and checks component files; off the main thread.
        applications = await Task.detached(priority: .userInitiated) {
            ApplicationCatalog.load(context: context)
        }.value
    }

    private func noteTransitions(to status: MonadoStatus) {
        let state = status.serviceState
        defer { lastServiceState = state }
        guard let previous = lastServiceState, previous != state else { return }
        switch (previous, state) {
        case (.running, .idle):
            if let job = status.job, job.lastExitWasAbnormal {
                let detail = [job.lastExitCode.map { "exit code \($0)" }, job.lastTerminatingSignal].compactMap { $0 }.joined(separator: ", ")
                record(.warning, "Monado exited unexpectedly (\(detail)). See the service log.")
            } else {
                record(.info, "Monado stopped.")
            }
        case let (_, .running(pid)):
            record(.info, "Monado is running (pid \(pid)).")
        case (_, .notLoaded):
            record(.warning, "Monado's LaunchAgent is no longer loaded.")
        default:
            break
        }
    }

    // MARK: Service control

    func perform(_ action: ServiceAction) {
        guard busyAction == nil else { return }
        busyAction = action
        Task {
            defer { busyAction = nil }
            do {
                switch action {
                case .start: try await controller.start()
                case .stop: try await controller.stop()
                case .forceStop: try await controller.forceStop()
                case .restart: try await controller.restart()
                case .load: try await controller.load()
                case .reload: try await controller.reload()
                case .query: break
                }
                if action == .stop || action == .forceStop { offerForceStop = false }
                if action != .query { record(.info, "\(action.rawValue) Monado succeeded.") }
                await refreshStatus(explicitQuery: action == .query)
            } catch {
                if case LaunchdServiceError.stopTimedOut = error { offerForceStop = true }
                record(.error, "\(action.rawValue) Monado failed: \(error.localizedDescription)")
                self.error = UserFacingError("\(action.rawValue) Monado failed", error)
                await refreshStatus()
            }
        }
    }

    // MARK: Monado settings

    var monadoSettingsStore: MonadoSettingsStore? {
        guard let agent = monado?.installation.agentPlistURL else { return nil }
        let backups = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Threshold XR/Backups/LaunchAgents")
        return MonadoSettingsStore(agentURL: agent, backupDirectory: backups)
    }

    private func loadMonadoSettings(status: MonadoStatus) {
        guard let store = monadoSettingsStore else { return }
        do {
            monadoSettings = try store.read(
                loadedEnvironment: status.job?.isLoaded == true ? status.job?.environment : nil,
                serviceExecutable: status.installation.serviceExecutable
            )
            monadoSettingsError = nil
        } catch {
            monadoSettings = []
            monadoSettingsError = error.localizedDescription
        }
    }

    /// Writes staged Monado setting changes to the LaunchAgent (with a backup).
    func saveMonadoSettings(_ changes: [String: SettingValue?]) async -> Bool {
        guard let store = monadoSettingsStore, !changes.isEmpty else { return false }
        do {
            let backup = try store.write(changes)
            lastBackup = backup
            let names = changes.keys.compactMap { SettingsCatalog.descriptor(id: $0)?.title }.sorted().joined(separator: ", ")
            record(.info, "Saved Monado settings (\(names)). Previous LaunchAgent backed up to \(backup.path).")
            await refreshStatus()
            return true
        } catch {
            record(.error, "Saving Monado settings failed: \(error.localizedDescription)")
            self.error = UserFacingError("Could not save Monado settings", error)
            return false
        }
    }

    // MARK: Direct launch

    /// Threshold Home's catalog and threshold-runtime's applications, as launch targets.
    var launchTargets: [LaunchTarget] { applications.targets }

    func launch(_ target: LaunchTarget) {
        Task {
            // Use fresh status for the preflight and the connection baseline.
            await refreshStatus()
            do {
                try await launches.launch(target, monado: monado)
                record(.info, "Launched \(target.title) directly (\(target.url.path)).")
            } catch {
                record(.error, "Launching \(target.title) failed: \(error.localizedDescription)")
                self.error = UserFacingError("Could not launch \(target.title)", error)
            }
        }
    }

    func stopLaunch(_ record: LaunchRecord) {
        self.record(.info, "Stopping \(record.title).")
        launches.stop(record.id)
    }

    private func noteLaunchChange(_ launch: LaunchRecord) {
        let previous = lastLaunchPhases[launch.id]
        guard previous != launch.phase else { return }
        lastLaunchPhases[launch.id] = launch.phase
        switch launch.phase {
        case .connected:
            record(.info, "\(launch.title) connected to Monado.")
        case .presenting:
            record(.info, "\(launch.title) is presenting in the headset\(launch.clientName.map { " (client \"\($0)\")" } ?? "").")
        case .exited:
            record(.info, "\(launch.title) \(launch.stopRequested ? "stopped" : "exited") (\(launch.exit?.description ?? "no status")).")
        case .crashed:
            let report = launch.crashReport.map { " Crash report: \($0.path)." } ?? ""
            record(.error, "\(launch.title) crashed (\(launch.exit?.description ?? "no status")).\(report)")
        case let .failed(message):
            record(.error, "\(launch.title) failed: \(message)")
        default:
            break
        }
    }

    // MARK: Paths and launching

    func setOverride(_ path: String?, for id: ComponentID) {
        preferences.setPathOverride(path, for: id)
        record(.info, path.map { "Detection path for \(id.displayName) set to \($0)." } ?? "Detection path override for \(id.displayName) cleared.")
        preferencesChanged()
    }

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Opens Threshold Home (SwiftXR Shell). It connects to Monado as an
    /// ordinary client, so launchd starts the service on demand if needed.
    // MARK: Threshold Home

    /// Threshold Home's latest status while it runs (nil when it is not running).
    var homeStatus: HomeStatus?
    var homeBusy: HomeTransition?
    enum HomeTransition: String { case starting = "Starting", stopping = "Stopping" }

    @ObservationIgnored private lazy var homeClient: HomeControlClient = {
        let client = HomeControlClient()
        client.onStatus = { [weak self] status in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.homeStatus == nil { self.record(.info, "Connected to Threshold Home (pid \(status.pid)).") }
                self.homeStatus = status
                if self.homeBusy == .starting { self.homeBusy = nil }
            }
        }
        client.onDisconnect = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.homeStatus != nil { self.record(.info, "Threshold Home stopped.") }
                self.homeStatus = nil
                if self.homeBusy == .stopping { self.homeBusy = nil }
            }
        }
        return client
    }()

    /// Connects to a running Home; cheap enough to call on every refresh.
    func connectToHomeIfRunning() {
        if !homeClient.isConnected { homeClient.connect() }
    }

    /// The Home app to launch: the helper inside Threshold XR.app, else a
    /// separately installed SwiftXR Shell (development builds).
    var homeApplicationURL: URL? {
        let embedded = Bundle.main.bundleURL.appending(path: "Contents/Helpers/Threshold Home.app")
        if FileManager.default.fileExists(atPath: embedded.path) { return embedded }
        guard let home = components.first(where: { $0.id == .thresholdHome }),
              let app = home.artifacts.first(where: { $0.kind == .bundle && $0.exists }) else { return nil }
        return URL(fileURLWithPath: app.path)
    }

    var thresholdHomeAvailable: Bool { homeApplicationURL != nil }

    func launchThresholdHome() {
        guard homeStatus == nil, homeBusy == nil else { return }
        guard let url = homeApplicationURL else {
            error = UserFacingError("Threshold Home was not found",
                                    message: "This copy of Threshold XR has no Threshold Home helper, and no SwiftXR Shell is installed.",
                                    suggestion: "Build the app with scripts/make-app.zsh, which includes Threshold Home.")
            return
        }
        homeBusy = .starting
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // A separately installed Shell runs headless too; its status shows here.
        configuration.arguments = ["--managed"]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.homeBusy = nil
                    self.record(.error, "Starting Threshold Home failed: \(error.localizedDescription)")
                    self.error = UserFacingError("Could not start Threshold Home", error)
                    return
                }
                self.record(.info, "Started Threshold Home from \(url.path).")
                // Home serves its control channel once it has launched.
                for _ in 0..<40 where self.homeStatus == nil {
                    self.connectToHomeIfRunning()
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if self.homeBusy == .starting { self.homeBusy = nil }
            }
        }
    }

    /// Asks Home to quit cleanly, then forces it only if it does not.
    func stopThresholdHome() {
        guard let status = homeStatus, homeBusy == nil else { return }
        homeBusy = .stopping
        homeClient.send(.quit)
        let pid = status.pid
        Task {
            for _ in 0..<32 where homeStatus != nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if homeStatus != nil, let app = NSRunningApplication(processIdentifier: pid) {
                record(.warning, "Threshold Home did not quit; forcing it to stop.")
                app.forceTerminate()
            }
            homeBusy = nil
        }
    }

    /// Stops Home and starts it again, e.g. after granting a permission.
    func restartThresholdHome() {
        stopThresholdHome()
        Task {
            for _ in 0..<60 where homeStatus != nil || homeBusy != nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            launchThresholdHome()
        }
    }

    func sendToHome(_ command: HomeCommand) {
        guard homeClient.send(command) else {
            record(.warning, "Threshold Home is not running.")
            return
        }
    }

    // MARK: Activity log

    func record(_ level: ActivityEntry.Level, _ message: String) {
        activity.append(ActivityEntry(level: level, message: message))
        if activity.count > 500 { activity.removeFirst(activity.count - 500) }
        switch level {
        case .info: log.info("\(message, privacy: .public)")
        case .warning: log.warning("\(message, privacy: .public)")
        case .error: log.error("\(message, privacy: .public)")
        }
    }

    func abbreviate(_ path: String) -> String {
        PathTools.abbreviate(path, home: context.homeDirectory)
    }
}
