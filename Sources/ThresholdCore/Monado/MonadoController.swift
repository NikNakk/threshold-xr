import Foundation

/// Decides whether it is safe to connect to Monado through libmonado.
///
/// Two behaviours of the installed service make an unconditional probe
/// disruptive:
///  - With no listening socket, libmonado asks launchd to start the service
///    over XPC, which claims the headset.
///  - With idle exit enabled, any client disconnect that leaves zero clients
///    starts the exit timer, so probing an otherwise idle, manually started
///    service would stop it a few seconds later.
/// The policy therefore queries automatically only when the service is
/// running, listening and already has at least one other client.
public struct RuntimeQueryPolicy: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case query
        case skip(String)
    }

    public var automaticQueriesEnabled: Bool
    public var minimumInterval: TimeInterval

    public init(automaticQueriesEnabled: Bool = true, minimumInterval: TimeInterval = 10) {
        self.automaticQueriesEnabled = automaticQueriesEnabled
        self.minimumInterval = minimumInterval
    }

    public func decide(
        job: LaunchdJobStatus?,
        sockets: ProcessSocketSummary?,
        socketPath: String,
        agentEnvironment: [String: String],
        explicitRequest: Bool
    ) -> Decision {
        guard let job, job.isRunning else {
            return .skip("The service is not running. Connecting would start it.")
        }
        guard let sockets else {
            return .skip("The service's sockets could not be inspected, so a connection might start a new instance.")
        }
        guard sockets.isListening(on: socketPath) else {
            return .skip("The service is not listening on its IPC socket yet.")
        }
        if explicitRequest { return .query }
        guard automaticQueriesEnabled else { return .skip("Automatic runtime queries are turned off in Settings.") }
        let idleExit = Self.isTrue(agentEnvironment["IPC_EXIT_WHEN_IDLE"])
        if sockets.connectedCount == 0 && idleExit {
            return .skip("No applications are connected. Querying now would start Monado's idle-exit timer, so details are read only while an application is connected.")
        }
        return .query
    }

    static func isTrue(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return ["1", "true", "yes", "on", "y"].contains(value)
    }
}

/// Reads a runtime snapshot through libmonado.
public protocol RuntimeQuerying: Sendable {
    func snapshot(libmonado: URL) throws -> MonadoRuntimeSnapshot
}

/// Keeps one loaded libmonado per path.
public final class LibMonadoQuerier: RuntimeQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private var libraries: [URL: LibMonado] = [:]

    public init() {}

    public func snapshot(libmonado: URL) throws -> MonadoRuntimeSnapshot {
        let library: LibMonado = try lock.withLock {
            if let existing = libraries[libmonado] { return existing }
            let loaded = try LibMonado(url: libmonado)
            libraries[libmonado] = loaded
            return loaded
        }
        return try library.snapshot()
    }
}

/// Discovers Monado's state and controls its existing LaunchAgent.
///
/// This type never edits Monado's property list or the system OpenXR
/// registration; see ``MonadoSettingsStore`` for explicit setting changes.
public actor MonadoController {
    public let context: DiscoveryContext
    public let service: LaunchdService
    private let sockets: any ProcessSocketInspecting
    private let usb: any USBDeviceEnumerating
    private let querier: any RuntimeQuerying
    public var policy: RuntimeQueryPolicy

    private var lastQuery: (date: Date, result: MonadoStatus.RuntimeQuery)?
    private var cachedInstallation: (key: String, value: MonadoInstallation)?

    public init(
        context: DiscoveryContext,
        runner: any CommandRunning = ProcessCommandRunner(),
        sockets: any ProcessSocketInspecting = LibprocSocketInspector(),
        usb: any USBDeviceEnumerating = IOKitUSBEnumerator(),
        querier: any RuntimeQuerying = LibMonadoQuerier(),
        policy: RuntimeQueryPolicy = RuntimeQueryPolicy()
    ) {
        self.context = context
        self.service = LaunchdService(label: MonadoInstallation.serviceLabel, domain: context.launchdDomain, runner: runner)
        self.sockets = sockets
        self.usb = usb
        self.querier = querier
        self.policy = policy
    }

    public func setPolicy(_ policy: RuntimeQueryPolicy) { self.policy = policy }

    /// Gathers the current status. `explicitQuery` asks for a libmonado
    /// query even when no other client is connected (the user accepted that
    /// it may start the idle-exit timer).
    public func refresh(explicitQuery: Bool = false) async -> MonadoStatus {
        let installation = discoverInstallation()
        let sessionRuntime = await service.sessionEnvironmentValue("XR_RUNTIME_JSON")
        let registration = OpenXRRegistration.discover(context: context, sessionOverride: sessionRuntime)

        var job: LaunchdJobStatus?
        var jobError: String?
        do { job = try await service.status() } catch { jobError = error.localizedDescription }

        let socketURL = installation.socketURL(context: context)
        let socketSummary = job?.pid.flatMap { sockets.sockets(of: $0) }

        let decision = policy.decide(
            job: job,
            sockets: socketSummary,
            socketPath: socketURL.path,
            agentEnvironment: installation.agent?.environment ?? [:],
            explicitRequest: explicitQuery
        )
        let query: MonadoStatus.RuntimeQuery
        switch decision {
        case let .skip(reason):
            query = .notAttempted(reason)
            if job?.isRunning != true { lastQuery = nil }
        case .query:
            if !explicitQuery, let last = lastQuery, Date().timeIntervalSince(last.date) < policy.minimumInterval {
                query = last.result
            } else if let libmonado = installation.libmonadoURL {
                do {
                    query = .succeeded(try querier.snapshot(libmonado: libmonado))
                } catch {
                    query = .failed(error.localizedDescription)
                }
                lastQuery = (Date(), query)
            } else {
                query = .notAttempted("libmonado was not found in the Monado installation.")
            }
        }

        return MonadoStatus(
            installation: installation,
            registration: registration,
            job: job,
            jobError: jobError,
            socketPath: socketURL.path,
            socketFileExists: FileProbe.isSocket(socketURL),
            sockets: socketSummary,
            runtimeQuery: query,
            headsetUSB: PSVR2USB.state(from: usb.devices(vendorID: PSVR2USB.vendorID)),
            checkedAt: Date()
        )
    }

    /// Installation discovery scans the service binary for its build tag,
    /// so it is cached until the binary or plist changes.
    private func discoverInstallation() -> MonadoInstallation {
        let plist = context.home("Library/LaunchAgents/\(MonadoInstallation.serviceLabel).plist")
        let plistDate = FileProbe.modificationDate(plist)?.timeIntervalSince1970 ?? 0
        let override = context.override(for: .monado)?.path ?? ""
        var serviceDate: TimeInterval = 0
        if let cached = cachedInstallation?.value.serviceExecutable {
            serviceDate = FileProbe.modificationDate(cached)?.timeIntervalSince1970 ?? 0
        }
        let key = "\(plistDate)|\(override)|\(serviceDate)"
        if let cachedInstallation, cachedInstallation.key == key { return cachedInstallation.value }
        let value = MonadoInstallation.discover(context: context)
        let newServiceDate = value.serviceExecutable.flatMap(FileProbe.modificationDate)?.timeIntervalSince1970 ?? 0
        cachedInstallation = ("\(plistDate)|\(override)|\(newServiceDate)", value)
        return value
    }

    // MARK: Service actions

    public func start() async throws { try await service.start() }
    public func stop() async throws { try await service.stop() }
    public func forceStop() async throws { try await service.forceStop() }
    public func restart() async throws { try await service.restart() }

    /// Loads the existing LaunchAgent plist into the login session.
    public func load() async throws {
        try await service.load(plist: context.home("Library/LaunchAgents/\(MonadoInstallation.serviceLabel).plist"))
    }

    /// Applies saved property-list changes by unloading and reloading the
    /// job. This stops a running service, so callers confirm first.
    public func reload() async throws {
        try await service.reload(plist: context.home("Library/LaunchAgents/\(MonadoInstallation.serviceLabel).plist"))
    }
}
