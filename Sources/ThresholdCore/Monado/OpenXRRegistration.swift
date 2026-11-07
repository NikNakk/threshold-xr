import Foundation

/// A parsed OpenXR runtime manifest (`openxr_monado.json`, `active_runtime.json`).
public struct OpenXRRuntimeManifest: Sendable, Equatable {
    public var url: URL
    public var name: String?
    public var fileFormatVersion: String?
    /// `runtime.library_path`, resolved against the manifest's real directory.
    public var libraryURL: URL?
    /// Monado's `runtime.MND_libmonado_path` extension, resolved the same way.
    public var libmonadoURL: URL?

    public static func load(_ url: URL) -> OpenXRRuntimeManifest? {
        guard let json = FileProbe.readJSONObject(url),
              let runtime = json["runtime"] as? [String: Any] else { return nil }
        // Relative paths are relative to the manifest file itself, after
        // following symlinks (the loader and SwiftXR both do this).
        let base = FileProbe.resolved(url).deletingLastPathComponent()
        func resolve(_ value: Any?) -> URL? {
            guard let path = value as? String, !path.isEmpty else { return nil }
            if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
            return base.appending(path: path).standardizedFileURL
        }
        return OpenXRRuntimeManifest(
            url: url,
            name: runtime["name"] as? String,
            fileFormatVersion: json["file_format_version"] as? String,
            libraryURL: resolve(runtime["library_path"]),
            libmonadoURL: resolve(runtime["MND_libmonado_path"])
        )
    }

    public var libraryExists: Bool { libraryURL.map(FileProbe.exists) ?? false }
}

/// One place the OpenXR loader may look for the active runtime.
public struct ActiveRuntimeCandidate: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable {
        case userConfig = "XDG_CONFIG_HOME"
        case xdgConfigDirs = "XDG_CONFIG_DIRS"
        case systemConfig = "System configuration"
        case localShare = "/usr/local/share"
    }

    public var id: String { url.path }
    public var url: URL
    public var source: Source
    public var exists: Bool
    public var symlinkTarget: String?
    public var manifest: OpenXRRuntimeManifest?
}

/// How OpenXR applications on this Mac will find a runtime. Read-only:
/// Threshold XR never changes the registration without an explicit action.
public struct OpenXRRegistration: Sendable, Equatable {
    /// `XR_RUNTIME_JSON` in launchd's user-session environment, inherited by
    /// GUI applications (set at login by Monado's client-environment agent).
    public var sessionOverride: String?
    /// `XR_RUNTIME_JSON` in Threshold XR's own environment.
    public var processOverride: String?
    public var candidates: [ActiveRuntimeCandidate]

    /// The manifest a GUI application would load: the session override if
    /// set, else the first existing active runtime.
    public var effectiveManifest: OpenXRRuntimeManifest? {
        if let path = sessionOverride, let manifest = OpenXRRuntimeManifest.load(URL(fileURLWithPath: path)) {
            return manifest
        }
        return activeRuntime?.manifest
    }

    public var activeRuntime: ActiveRuntimeCandidate? { candidates.first(where: \.exists) }

    /// Whether the effective runtime is the given Monado runtime manifest.
    public func selects(_ manifest: OpenXRRuntimeManifest?) -> Bool {
        guard let manifest, let effective = effectiveManifest else { return false }
        if FileProbe.resolved(effective.url) == FileProbe.resolved(manifest.url) { return true }
        if let a = effective.libraryURL, let b = manifest.libraryURL {
            return FileProbe.resolved(a) == FileProbe.resolved(b)
        }
        return false
    }

    /// Whether the system-wide registration (ignoring session overrides)
    /// selects the given manifest.
    public func systemSelects(_ manifest: OpenXRRuntimeManifest?) -> Bool {
        guard let manifest, let active = activeRuntime?.manifest else { return false }
        if FileProbe.resolved(active.url) == FileProbe.resolved(manifest.url) { return true }
        if let a = active.libraryURL, let b = manifest.libraryURL {
            return FileProbe.resolved(a) == FileProbe.resolved(b)
        }
        return false
    }

    /// Candidate locations in the Khronos loader's order for macOS: the
    /// user's XDG config directory, XDG_CONFIG_DIRS (default /etc/xdg), the
    /// compiled-in system configuration directories, then
    /// /usr/local/share, which is where this installation's loader finds Monado.
    public static func candidateDirectories(context: DiscoveryContext) -> [(URL, ActiveRuntimeCandidate.Source)] {
        var dirs: [(URL, ActiveRuntimeCandidate.Source)] = []
        let configHome = context.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? context.home(".config")
        dirs.append((configHome.appending(path: "openxr/1"), .userConfig))
        let configDirs = context.environment["XDG_CONFIG_DIRS"] ?? "/etc/xdg"
        for dir in configDirs.split(separator: ":") where !dir.isEmpty {
            dirs.append((URL(fileURLWithPath: String(dir)).appending(path: "openxr/1"), .xdgConfigDirs))
        }
        dirs.append((URL(fileURLWithPath: "/usr/local/etc/openxr/1"), .systemConfig))
        dirs.append((URL(fileURLWithPath: "/etc/openxr/1"), .systemConfig))
        dirs.append((URL(fileURLWithPath: "/usr/local/share/openxr/1"), .localShare))
        return dirs
    }

    public static func discover(
        context: DiscoveryContext,
        sessionOverride: String?,
        directories: [(URL, ActiveRuntimeCandidate.Source)]? = nil
    ) -> OpenXRRegistration {
        var candidates: [ActiveRuntimeCandidate] = []
        for (dir, source) in directories ?? candidateDirectories(context: context) {
            // The loader prefers an architecture-decorated file.
            for name in ["active_runtime.aarch64.json", "active_runtime.json"] {
                let url = dir.appending(path: name)
                let exists = FileProbe.exists(url)
                if !exists && name != "active_runtime.json" { continue }
                candidates.append(ActiveRuntimeCandidate(
                    url: url,
                    source: source,
                    exists: exists,
                    symlinkTarget: FileProbe.symlinkDestination(url),
                    manifest: exists ? OpenXRRuntimeManifest.load(url) : nil
                ))
            }
        }
        return OpenXRRegistration(
            sessionOverride: sessionOverride,
            processOverride: context.environment["XR_RUNTIME_JSON"],
            candidates: candidates
        )
    }
}
