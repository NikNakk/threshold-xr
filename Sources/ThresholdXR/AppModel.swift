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
    var shellApps: [ShellAppEntry] = []
    var shellAppsError: String?

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
                try? await Task.sleep(for: .seconds(self.preferences.refreshInterval))
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
        do {
            shellApps = try ShellAppCatalog.load(context: context)
            shellAppsError = nil
        } catch {
            shellApps = []
            shellAppsError = error.localizedDescription
        }
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
    func launchThresholdHome() {
        guard let home = components.first(where: { $0.id == .thresholdHome }),
              let app = home.artifacts.first(where: { $0.kind == .bundle && $0.exists }) else {
            error = UserFacingError("Threshold Home was not found",
                                    message: "No SwiftXR Shell application was detected.",
                                    suggestion: "Install it with SwiftXRShell/scripts/make-app.zsh, or set its path on the Components screen.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.record(.error, "Launching Threshold Home failed: \(error.localizedDescription)")
                    self?.error = UserFacingError("Could not launch Threshold Home", error)
                } else {
                    self?.record(.info, "Launched Threshold Home from \(app.path).")
                }
            }
        }
    }

    var thresholdHomeAvailable: Bool {
        components.first(where: { $0.id == .thresholdHome })?.artifacts.contains { $0.kind == .bundle && $0.exists } ?? false
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
