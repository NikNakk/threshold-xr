import Foundation

/// Stable identifiers for managed components. Raw values are persisted (path
/// overrides) and will be used as keys in the future installer manifest.
public enum ComponentID: String, Sendable, CaseIterable, Codable, Identifiable {
    case monado
    case openXRLoader = "openxr-loader"
    case xrizer
    case dxmt
    case kosmicKrisp = "kosmickrisp"
    case wine
    case wineXR = "wine-xr"
    case alyxHost = "alyx-host"
    case questHost = "quest-host"
    case thresholdHome = "threshold-home"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .monado: return "Monado"
        case .openXRLoader: return "OpenXR Loader"
        case .xrizer: return "xrizer"
        case .dxmt: return "DXMT"
        case .kosmicKrisp: return "KosmicKrisp"
        case .wine: return "Wine"
        case .wineXR: return "Wine XR Integration"
        case .alyxHost: return "Native Alyx Host"
        case .questHost: return "Quest Host"
        case .thresholdHome: return "Threshold Home"
        }
    }

    public var role: ComponentRole {
        switch self {
        case .monado: return .runtime
        case .openXRLoader: return .loader
        case .xrizer: return .openVRTranslation
        case .dxmt: return .graphicsTranslation
        case .kosmicKrisp: return .vulkanDriver
        case .wine: return .compatibilityLayer
        case .wineXR: return .integration
        case .alyxHost, .questHost: return .applicationHost
        case .thresholdHome: return .immersiveShell
        }
    }

    public var summary: String {
        switch self {
        case .monado: return "OpenXR runtime, compositor and PS VR2 driver."
        case .openXRLoader: return "Khronos loader that applications use to find the active runtime."
        case .xrizer: return "OpenVR-to-OpenXR translation, used natively by Alyx and inside Wine."
        case .dxmt: return "Direct3D 10/11 to Metal translation, installed into a Wine runtime."
        case .kosmicKrisp: return "Mesa Vulkan driver for Metal, selected by Vulkan ICD manifest."
        case .wine: return "CrossOver-based Wine runtimes for Windows applications."
        case .wineXR: return "macOS Wine XR bridge, Steam Play tool and Windows game runner."
        case .alyxHost: return "Native ARM64 Half-Life: Alyx host and launchers."
        case .questHost: return "Experimental Android/Quest OpenXR application host."
        case .thresholdHome: return "Immersive SwiftXR home environment (currently SwiftXR Shell)."
        }
    }

    /// Hint shown next to the path override field.
    public var overrideHint: String {
        switch self {
        case .monado: return "Monado install prefix or monado-service path"
        case .openXRLoader: return "libopenxr_loader.dylib"
        case .xrizer: return "libxrizer.dylib (native build)"
        case .dxmt: return "Wine runtime containing DXMT, or DXMT install directory"
        case .kosmicKrisp: return "KosmicKrisp ICD .json or libvulkan_kosmickrisp.dylib"
        case .wine: return "Wine runtime directory (containing bin/wine)"
        case .wineXR: return "macos-wine-xr checkout"
        case .alyxHost: return "alyx-native workspace"
        case .questHost: return "quest-host directory"
        case .thresholdHome: return "SwiftXR Shell.app or swiftxr-shell executable"
        }
    }
}

/// What a component does. Not every component is an application: DXMT is
/// installed into Wine, KosmicKrisp is chosen by a Vulkan ICD manifest and
/// xrizer is loaded as an OpenVR runtime library.
public enum ComponentRole: String, Sendable, Codable {
    case runtime = "OpenXR runtime"
    case loader = "Loader"
    case openVRTranslation = "OpenVR translation"
    case graphicsTranslation = "Graphics translation"
    case vulkanDriver = "Vulkan driver"
    case compatibilityLayer = "Compatibility layer"
    case integration = "Integration"
    case applicationHost = "Application host"
    case immersiveShell = "Immersive shell"
}

public enum ArtifactKind: String, Sendable, Codable {
    case executable, library, manifest, bundle, directory, sourceCheckout, launcher, configuration
}

/// How an artifact's location was found, so users can tell an explicit
/// override from a guess.
public enum ArtifactSource: String, Sendable, Codable {
    case userOverride = "Override"
    case environment = "Environment"
    case launchAgent = "LaunchAgent"
    case launchProfile = "Launch profile"
    case registration = "Registration"
    case knownLocation = "Known location"
    case workspace = "Developer workspace"
}

/// One file or directory that makes up part of a component.
public struct DetectedArtifact: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(role)|\(path)" }
    public var role: String
    public var kind: ArtifactKind
    public var path: String
    public var exists: Bool
    public var source: ArtifactSource
    public var version: String?
    public var detail: String?

    public init(role: String, kind: ArtifactKind, url: URL, source: ArtifactSource, version: String? = nil, detail: String? = nil) {
        self.role = role
        self.kind = kind
        self.path = url.path
        self.exists = FileProbe.exists(url)
        self.source = source
        self.version = version
        self.detail = detail
    }
}

public enum DetectionState: String, Sendable, Codable, Comparable {
    case detected = "Detected"
    case partial = "Incomplete"
    case notFound = "Not found"

    private var order: Int {
        switch self { case .detected: 0; case .partial: 1; case .notFound: 2 }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

/// A remark about a component. Warnings describe problems the user may need
/// to act on; info notes explain how the component is used.
public struct ComponentNote: Sendable, Equatable, Hashable, ExpressibleByStringInterpolation {
    public enum Severity: Sendable, Equatable, Hashable { case info, warning }
    public var severity: Severity
    public var text: String

    public init(_ severity: Severity, _ text: String) {
        self.severity = severity
        self.text = text
    }

    public init(stringLiteral value: String) { self.init(.info, value) }

    public static func warning(_ text: String) -> ComponentNote { ComponentNote(.warning, text) }
}

public struct ComponentStatus: Sendable, Equatable, Identifiable {
    public var id: ComponentID
    public var state: DetectionState
    public var version: String?
    /// The main location to show for the component.
    public var location: String?
    public var artifacts: [DetectedArtifact]
    public var notes: [ComponentNote]
    public var source: GitCheckoutInfo?

    public init(
        id: ComponentID,
        state: DetectionState,
        version: String? = nil,
        location: String? = nil,
        artifacts: [DetectedArtifact] = [],
        notes: [ComponentNote] = [],
        source: GitCheckoutInfo? = nil
    ) {
        self.id = id
        self.state = state
        self.version = version
        self.location = location
        self.artifacts = artifacts
        self.notes = notes
        self.source = source
    }
}
