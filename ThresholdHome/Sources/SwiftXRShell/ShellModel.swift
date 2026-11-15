import Foundation
import SwiftUI
import ThresholdCore

@MainActor
enum ShellCommand {
    case launch(ShellApplication)
    case stopExternalApplication
    case settings
}

struct ShellApplication: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case videoPlayer
        case virtualDesktop
        case browser
        case browserViz
        case resumeObservedExternal
        case external(ExternalOpenXRApplication)
    }

    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let kind: Kind

    static let videoPlayer = ShellApplication(
        id: "swiftxr.video",
        title: "Video",
        subtitle: "VR180, 360, EAC and flat video",
        systemImage: "play.rectangle.fill",
        kind: .videoPlayer
    )

    static let virtualDesktop = ShellApplication(
        id: "swiftxr.desktop",
        title: "Desktop",
        subtitle: "View and control your Mac",
        systemImage: "desktopcomputer",
        kind: .virtualDesktop
    )

    static let browser = ShellApplication(
        id: "swiftxr.browser",
        title: "Browser",
        subtitle: "Chromium, WebXR and the web",
        systemImage: "globe",
        kind: .browser
    )

    static let browserViz = ShellApplication(
        id: "swiftxr.browser-viz",
        title: "Browser (Viz)",
        subtitle: "Compare offscreen Chromium · GPU surface",
        systemImage: "rectangle.on.rectangle",
        kind: .browserViz
    )

    static func resumeObservedExternal(title: String) -> ShellApplication {
        ShellApplication(
            id: "swiftxr.resume-external",
            title: "Resume \(title)",
            subtitle: "Return to the active immersive OpenXR session",
            systemImage: "play.circle.fill",
            kind: .resumeObservedExternal
        )
    }
}

/// A titled group of Home tiles.
struct ShellApplicationSection: Identifiable {
    var title: String?
    var applications: [ShellApplication]
    var id: String { title ?? "home" }
}

extension ShellApplication {
    /// The shared-list source of an external application; nil for Home's own apps.
    var source: ApplicationCatalog.Source? {
        if case let .external(external) = kind { return external.target.source }
        return nil
    }
}

/// An application Home starts and hands the headset to: a shared
/// `LaunchTarget` (ThresholdCore) plus how Home handles its start-up.
struct ExternalOpenXRApplication: Hashable, Sendable {
    var target: LaunchTarget
    /// How long to wait for the app's Monado client before giving up.
    var openXRClientTimeout: TimeInterval
    /// How long Stop waits after the first request before forcing it.
    var stopGracePeriod: TimeInterval
    /// Keep Home on screen (with Stop) until the app's client takes the HMD,
    /// instead of an empty view for the whole start-up.
    var showsHomeWhileStarting: Bool

    init(
        target: LaunchTarget,
        openXRClientTimeout: TimeInterval? = nil,
        stopGracePeriod: TimeInterval? = nil,
        showsHomeWhileStarting: Bool? = nil
    ) {
        self.target = target
        self.openXRClientTimeout = openXRClientTimeout ?? target.clientTimeout ?? 30
        self.stopGracePeriod = stopGracePeriod ?? target.stopGracePeriod ?? 2
        // Apps known to start slowly keep Home on screen while they load.
        self.showsHomeWhileStarting = showsHomeWhileStarting ?? (target.clientTimeout != nil)
    }

    var executableURL: URL { target.url }
    var arguments: [String] { target.arguments }
    var environment: [String: String] { target.environment }
    var openXRApplicationName: String? { target.openXRApplicationName }
}

extension ShellApplication {
    /// A Home tile for an application from the shared catalog.
    init(target: LaunchTarget) {
        self.init(
            id: target.id,
            title: target.title,
            subtitle: target.subtitle ?? "OpenXR application",
            systemImage: target.systemImage ?? "arkit",
            kind: .external(ExternalOpenXRApplication(target: target))
        )
    }
}

/// The external app the launcher is handling, as shown in Home.
struct ShellExternalActivity: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case starting
        case running
        case stopping
    }

    let applicationID: String
    let title: String
    var phase: Phase
}

@MainActor
final class ShellModel: ObservableObject {
    @Published var usesTrackedControllers = false
    @Published var launchError: String?
    @Published private(set) var applications: [ShellApplication] = [
        .videoPlayer,
        .virtualDesktop,
        .browser,
        .browserViz,
    ]
    @Published private(set) var externalApplicationsEnabled = false
    /// The external app being started, running or stopped, if any.
    @Published var externalActivity: ShellExternalActivity?

    var commandHandler: ((ShellCommand) -> Void)?

    private var externalApplications: [ShellApplication] = []
    private var resumeApplication: ShellApplication?

    func launch(_ application: ShellApplication) {
        guard isLaunchEnabled(application) else { return }
        launchError = nil
        commandHandler?(.launch(application))
    }

    func isLaunchEnabled(_ application: ShellApplication) -> Bool {
        // Home stays on screen while some apps start; nothing else launches then.
        guard externalActivity == nil else { return false }
        if case .external = application.kind {
            return externalApplicationsEnabled
        }
        return true
    }

    func stopExternalApplication() {
        commandHandler?(.stopExternalApplication)
    }

    func setExternalApplicationsEnabled(_ enabled: Bool) {
        externalApplicationsEnabled = enabled
    }

    func openSettings() {
        commandHandler?(.settings)
    }

    func replaceExternalApplications(_ external: [ShellApplication]) {
        externalApplications = external
        rebuildApplications()
    }

    func showResumeObservedExternal(title: String) {
        resumeApplication = .resumeObservedExternal(title: title)
        rebuildApplications()
    }

    func clearResumeObservedExternal() {
        guard resumeApplication != nil else { return }
        resumeApplication = nil
        rebuildApplications()
    }

    /// Home's built-in apps first (untitled), then the shared list's sources
    /// under the same headings Threshold XR uses. Empty sources are left out.
    var applicationSections: [ShellApplicationSection] {
        var sections = [ShellApplicationSection(title: nil, applications: applications.filter { $0.source == nil })]
        for source in ApplicationCatalog.Source.allCases {
            let members = applications.filter { $0.source == source }
            if !members.isEmpty { sections.append(ShellApplicationSection(title: source.title, applications: members)) }
        }
        return sections
    }

    private func rebuildApplications() {
        var result: [ShellApplication] = []
        if let resumeApplication {
            result.append(resumeApplication)
        }
        result.append(.videoPlayer)
        result.append(.virtualDesktop)
        result.append(.browser)
        result.append(.browserViz)
        result.append(contentsOf: externalApplications)
        applications = result
    }
}
