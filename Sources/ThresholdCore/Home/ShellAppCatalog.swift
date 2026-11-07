import Foundation

/// An entry in SwiftXR Shell's external application catalog
/// (`~/Library/Application Support/SwiftXRShell/apps.json`). Threshold XR
/// reads the same file rather than keeping a second application list; the
/// format is documented in SwiftXR Shell's README.
public struct ShellAppEntry: Sendable, Equatable, Identifiable, Decodable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var systemImage: String?
    public var path: String
    public var arguments: [String]?
    public var environment: [String: String]?
    public var openXRApplicationName: String?
}

public enum ShellAppCatalog {
    public static func url(context: DiscoveryContext) -> URL {
        if let custom = context.environment["SWIFTXR_SHELL_APPS"] { return context.expand(custom) }
        return context.home("Library/Application Support/SwiftXRShell/apps.json")
    }

    public static func load(context: DiscoveryContext) throws -> [ShellAppEntry] {
        let url = url(context: context)
        guard FileProbe.exists(url) else { return [] }
        return try JSONDecoder().decode([ShellAppEntry].self, from: Data(contentsOf: url))
    }
}
