import Foundation

/// Everything discovery needs to know about the user's environment.
///
/// Discovery never hard-codes `/Users/<name>`: paths are built from the home
/// directory, the configured developer workspace, the process environment and
/// the user's own overrides. Tests substitute a temporary home directory.
public struct DiscoveryContext: Sendable {
    public var homeDirectory: URL
    public var userID: UInt32
    public var environment: [String: String]
    /// Root of the user's source checkouts (default `~/Code`). Used only to
    /// generate candidate locations for development builds.
    public var workspaceRoot: URL
    /// Root of the Windows compatibility rig (default `~/Windows`).
    public var windowsRigRoot: URL
    /// User-specified paths, keyed by `ComponentID.rawValue`. An override is
    /// tried before any other candidate.
    public var pathOverrides: [String: String]

    public init(
        homeDirectory: URL,
        userID: UInt32,
        environment: [String: String],
        workspaceRoot: URL? = nil,
        windowsRigRoot: URL? = nil,
        pathOverrides: [String: String] = [:]
    ) {
        self.homeDirectory = homeDirectory
        self.userID = userID
        self.environment = environment
        self.workspaceRoot = workspaceRoot ?? homeDirectory.appending(path: "Code")
        self.windowsRigRoot = windowsRigRoot ?? homeDirectory.appending(path: "Windows")
        self.pathOverrides = pathOverrides
    }

    /// The context of the current process.
    public static func current(
        workspaceRoot: String? = nil,
        windowsRigRoot: String? = nil,
        pathOverrides: [String: String] = [:]
    ) -> DiscoveryContext {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func expand(_ path: String?) -> URL? {
            guard let path, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: PathTools.expandTilde(path, home: home))
        }
        return DiscoveryContext(
            homeDirectory: home,
            userID: getuid(),
            environment: ProcessInfo.processInfo.environment,
            workspaceRoot: expand(workspaceRoot),
            windowsRigRoot: expand(windowsRigRoot),
            pathOverrides: pathOverrides
        )
    }

    public var launchdDomain: String { "gui/\(userID)" }

    public func home(_ relative: String) -> URL { homeDirectory.appending(path: relative) }
    public func workspace(_ relative: String) -> URL { workspaceRoot.appending(path: relative) }
    public func rig(_ relative: String) -> URL { windowsRigRoot.appending(path: relative) }

    public func expand(_ path: String) -> URL {
        URL(fileURLWithPath: PathTools.expandTilde(path, home: homeDirectory))
    }

    public func override(for id: ComponentID) -> URL? {
        guard let value = pathOverrides[id.rawValue]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        return expand(value)
    }
}

public enum PathTools {
    public static func expandTilde(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + String(path.dropFirst(1)) }
        return path
    }

    /// Replaces the home directory prefix with `~` for display.
    public static func abbreviate(_ path: String, home: URL) -> String {
        let homePath = home.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}
