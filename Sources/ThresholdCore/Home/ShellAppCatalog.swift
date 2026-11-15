import Foundation

/// An entry in Threshold Home's application catalog
/// (`~/Library/Application Support/SwiftXRShell/apps.json`). Threshold XR and
/// Threshold Home both read it through `ApplicationCatalog`; the format is
/// documented in ThresholdHome/README.md.
public struct ShellAppEntry: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var systemImage: String?
    public var path: String
    public var arguments: [String]?
    public var environment: [String: String]?
    public var openXRApplicationName: String?
}

public enum ShellAppCatalogError: Error, LocalizedError, Sendable, Equatable {
    case duplicateID(String)
    case emptyID
    case emptyTitle(String)
    case emptyPath(String)

    public var errorDescription: String? {
        switch self {
        case let .duplicateID(id): return "The catalog contains the id '\(id)' more than once."
        case .emptyID: return "The catalog contains an entry with an empty id."
        case let .emptyTitle(id): return "Application '\(id)' has an empty title."
        case let .emptyPath(id): return "Application '\(id)' has an empty path."
        }
    }
}

public enum ShellAppCatalog {
    public static func url(context: DiscoveryContext) -> URL {
        if let custom = context.environment["SWIFTXR_SHELL_APPS"], !custom.isEmpty { return context.expand(custom) }
        return context.home("Library/Application Support/SwiftXRShell/apps.json")
    }

    /// The catalog's entries, trimmed and checked. A missing file is an empty catalog.
    public static func load(context: DiscoveryContext) throws -> [ShellAppEntry] {
        let url = url(context: context)
        guard FileProbe.exists(url) else { return [] }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> [ShellAppEntry] {
        var seen = Set<String>()
        return try JSONDecoder().decode([ShellAppEntry].self, from: data).map { entry in
            var entry = entry
            entry.id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.id.isEmpty else { throw ShellAppCatalogError.emptyID }
            guard seen.insert(entry.id).inserted else { throw ShellAppCatalogError.duplicateID(entry.id) }
            guard !entry.title.isEmpty else { throw ShellAppCatalogError.emptyTitle(entry.id) }
            guard !entry.path.isEmpty else { throw ShellAppCatalogError.emptyPath(entry.id) }
            return entry
        }
    }

    /// Creates an empty catalog so there is a file to edit. Returns true if it created one.
    @discardableResult
    public static func createIfMissing(context: DiscoveryContext) throws -> Bool {
        let url = url(context: context)
        guard !FileProbe.exists(url) else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]\n".utf8).write(to: url, options: .atomic)
        return true
    }
}
