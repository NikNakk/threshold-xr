import Foundation

/// Monado's state, kept as separate facts. "Installed", "service running",
/// "runtime ready" and "headset connected" are independent: the service can
/// be running with no headset, and a headset can be plugged in while the
/// service is idle (it starts on demand when an application connects).
public struct MonadoStatus: Sendable, Equatable {
    public var installation: MonadoInstallation
    public var registration: OpenXRRegistration
    public var job: LaunchdJobStatus?
    public var jobError: String?
    public var socketPath: String
    public var socketFileExists: Bool
    public var sockets: ProcessSocketSummary?
    public var runtimeQuery: RuntimeQuery
    public var headsetUSB: HeadsetUSBState
    /// Problems in Monado's most recent run, from its service log.
    public var lastRun: MonadoRunReport? = nil
    public var checkedAt: Date

    public enum RuntimeQuery: Sendable, Equatable {
        case notAttempted(String)
        case succeeded(MonadoRuntimeSnapshot)
        case failed(String)

        public var snapshot: MonadoRuntimeSnapshot? {
            if case let .succeeded(snapshot) = self { snapshot } else { nil }
        }
    }

    // MARK: Installed

    public enum InstallState: Sendable, Equatable {
        case installed
        case missingServiceExecutable
        case notInstalled
    }

    public var installState: InstallState {
        if installation.isInstalled { return .installed }
        if installation.agent != nil { return .missingServiceExecutable }
        return .notInstalled
    }

    // MARK: Service

    public enum ServiceState: Sendable, Equatable {
        /// No LaunchAgent plist.
        case notRegistered
        /// The plist exists but launchd has not loaded it.
        case notLoaded
        /// Loaded and waiting for on-demand activation.
        case idle
        case running(pid: Int32)
        case unknown(String)
    }

    public var serviceState: ServiceState {
        if let jobError { return .unknown(jobError) }
        guard let job else { return installation.agent == nil ? .notRegistered : .unknown("Not checked") }
        switch job.state {
        case .notLoaded: return installation.agent == nil ? .notRegistered : .notLoaded
        case .loadedIdle: return .idle
        case let .running(pid): return .running(pid: pid)
        case let .other(text): return .unknown(text)
        }
    }

    public var isServiceRunning: Bool { if case .running = serviceState { true } else { false } }

    // MARK: Runtime

    public enum RuntimeState: Sendable, Equatable {
        /// The service is not running. Applications will start it on demand
        /// if the LaunchAgent is loaded.
        case stopped
        /// Running, but not yet listening on its IPC socket.
        case starting
        /// Running and listening; applications can connect.
        case ready
        /// Running with a socket file, but its file table could not be read.
        case unverified
    }

    public var runtimeState: RuntimeState {
        guard isServiceRunning else { return .stopped }
        if let sockets {
            if sockets.isListening(on: socketPath) { return .ready }
            return .starting
        }
        return socketFileExists ? .unverified : .starting
    }

    /// Approximate number of connected IPC clients (including any
    /// applications and Threshold Home), from the service's open sockets.
    public var connectedClientEstimate: Int? {
        if let snapshot = runtimeQuery.snapshot { return snapshot.clients.count }
        return isServiceRunning ? sockets?.connectedCount : nil
    }

    // MARK: Headset

    public enum HeadsetState: Sendable, Equatable {
        /// Monado reports a head device (name from the runtime).
        case activeInRuntime(String)
        /// The headset is on USB; Monado is not currently using it (or was
        /// not queried).
        case connected
        case notDetected
    }

    public var headsetState: HeadsetState {
        if let head = runtimeQuery.snapshot?.headDevice, !head.name.localizedCaseInsensitiveContains("simulated") {
            return .activeInRuntime(head.name)
        }
        if headsetUSB.headsetPresent { return .connected }
        return .notDetected
    }

    // MARK: Registration

    public var isSystemRuntime: Bool { registration.systemSelects(installation.runtimeManifest) }
    public var isSessionRuntime: Bool { registration.selects(installation.runtimeManifest) }

    /// Environment differences between the plist on disk and the loaded job.
    /// Non-empty means saved settings will apply only after a reload.
    public var pendingEnvironmentChanges: [String] {
        guard let job, job.isLoaded, let agent = installation.agent else { return [] }
        // launchd adds XPC_SERVICE_NAME and similar to the loaded environment.
        let ignored: Set<String> = ["XPC_SERVICE_NAME", "OSLogRateLimit"]
        let saved = agent.environment
        let loaded = job.environment.filter { !ignored.contains($0.key) }
        guard !loaded.isEmpty || !saved.isEmpty else { return [] }
        let keys = Set(saved.keys).union(loaded.keys)
        return keys.filter { saved[$0] != loaded[$0] }.sorted()
    }
}
