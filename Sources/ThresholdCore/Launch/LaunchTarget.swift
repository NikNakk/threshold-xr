import Foundation

/// Something Threshold XR can start directly, without Threshold Home.
public struct LaunchTarget: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        /// A macOS application bundle, opened through Launch Services.
        case appBundle
        /// An executable or script, run as a child process with its output logged.
        case executable
        /// An application the guest-app framework provides, started through threshold-run.
        case frameworkProfile
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var systemImage: String?
    public var url: URL
    public var kind: Kind
    public var arguments: [String]
    /// Overrides applied on top of the login-session environment.
    public var environment: [String: String]
    /// The OpenXR application name the app reports, used to recognise its
    /// Monado client.
    public var openXRApplicationName: String?
    /// The framework profile this target starts (kind `.frameworkProfile`).
    public var frameworkProfileID: String?
    /// Reasons the target cannot start, known before launch (missing components).
    public var unavailableReasons: [String] = []
    /// The executable macOS names in crash reports, when it is not the target's own.
    public var hostProcessName: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        url: URL,
        kind: Kind? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        openXRApplicationName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.url = url
        self.kind = kind ?? (url.pathExtension == "app" ? .appBundle : .executable)
        self.arguments = arguments
        self.environment = environment
        self.openXRApplicationName = openXRApplicationName
    }

    /// A target for an entry in Threshold Home's catalog, so both use one list.
    public init(entry: ShellAppEntry, context: DiscoveryContext) {
        self.init(
            id: entry.id,
            title: entry.title,
            subtitle: entry.subtitle,
            systemImage: entry.systemImage,
            url: context.expand(entry.path),
            arguments: entry.arguments ?? [],
            environment: entry.environment ?? [:],
            openXRApplicationName: entry.openXRApplicationName
        )
    }

    /// A target for a framework application: threshold-run with the profile's id.
    public init(profile: FrameworkProfile, runner: URL) {
        self.init(
            id: "threshold-runtime.\(profile.id)",
            title: profile.title,
            subtitle: profile.subtitle,
            systemImage: profile.systemImage,
            url: runner,
            kind: .frameworkProfile,
            arguments: [profile.id],
            openXRApplicationName: profile.openXRApplicationName
        )
        frameworkProfileID = profile.id
        unavailableReasons = profile.missingComponents.map { "missing \($0)" }
        hostProcessName = profile.hostProcessName
    }

    /// The executable name macOS uses in crash reports.
    public var processName: String {
        if let hostProcessName { return hostProcessName }
        if kind == .appBundle,
           let info = FileProbe.readPlist(url.appending(path: "Contents/Info.plist")),
           let executable = info["CFBundleExecutable"] as? String {
            return executable
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Names that may identify this app's Monado client.
    public var clientNameCandidates: [String] {
        [openXRApplicationName, title, processName].compactMap { $0?.lowercased() }
    }
}

/// A problem found before launching.
public struct LaunchIssue: Sendable, Equatable, Hashable {
    public enum Severity: Sendable, Equatable, Hashable {
        /// The launch cannot go ahead.
        case blocking
        /// The app may start but probably will not reach the headset.
        case warning
        /// Worth knowing; nothing is wrong.
        case info
    }

    public var severity: Severity
    public var message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

/// Checks a target against the current runtime state.
public enum LaunchPreflight {
    public static func check(_ target: LaunchTarget, monado: MonadoStatus?, alreadyRunning: Bool) -> [LaunchIssue] {
        var issues: [LaunchIssue] = []
        let path = target.url.path

        if alreadyRunning {
            issues.append(.init(.blocking, "\(target.title) is already running from Threshold XR."))
        }
        switch target.kind {
        case .appBundle:
            if !FileProbe.isDirectory(target.url) {
                issues.append(.init(.blocking, "The application was not found at \(path)."))
            }
        case .executable, .frameworkProfile:
            if !FileProbe.exists(target.url) {
                issues.append(.init(.blocking, "The executable was not found at \(path)."))
            } else if !FileProbe.isExecutableFile(target.url) {
                issues.append(.init(.blocking, "\(path) is not executable."))
            }
        }

        for reason in target.unavailableReasons {
            issues.append(.init(.blocking, "\(target.title) cannot start: \(reason)."))
        }

        if target.environment["XR_RUNTIME_JSON"] != nil {
            issues.append(.init(.info, "This app selects its own OpenXR runtime manifest (XR_RUNTIME_JSON)."))
        } else if let monado {
            switch monado.serviceState {
            case .notRegistered:
                issues.append(.init(.warning, "Monado's LaunchAgent is not installed, so the runtime cannot start on demand."))
            case .notLoaded:
                issues.append(.init(.warning, "Monado's LaunchAgent is not loaded, so the runtime cannot start on demand. Load it on the Home screen."))
            default:
                break
            }
            if monado.installState != .installed {
                issues.append(.init(.warning, "Monado is not installed."))
            } else if !monado.isSessionRuntime {
                issues.append(.init(.warning, "Monado is not the OpenXR runtime for apps started from this login session."))
            }
            if monado.headsetState == .notDetected {
                issues.append(.init(.info, "The headset is not connected."))
            }
        }
        return issues
    }

    public static func canLaunch(_ issues: [LaunchIssue]) -> Bool {
        !issues.contains { $0.severity == .blocking }
    }
}
