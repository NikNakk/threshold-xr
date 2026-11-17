import Foundation

public enum ApplicationEditingError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case let .invalid(message): return message }
    }
}

/// Persists the shared catalog without replacing other applications or silently overwriting external edits.
public enum ApplicationEditing {
    public static func saveManual(_ data: Data, originalID: String?, original: Data?, context: DiscoveryContext) throws {
        let entry = try ShellAppCatalog.decode(Data("[".utf8) + data + Data("]".utf8))[0]
        let url = ShellAppCatalog.url(context: context)
        try checkUnchanged(url, original: original)
        var entries = try ShellAppCatalog.load(context: context)
        if let originalID { entries.removeAll { $0.id == originalID } }
        guard !entries.contains(where: { $0.id == entry.id }) else { throw ShellAppCatalogError.duplicateID(entry.id) }
        guard !entry.id.hasPrefix("steam."), !entry.id.hasPrefix("threshold-runtime.") else {
            throw ApplicationEditingError.invalid("Manual application IDs cannot use the reserved steam. or threshold-runtime. prefixes.")
        }
        entries.append(entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(encoder.encode(entries), to: url)
    }

    public static func checkUnchanged(_ url: URL, original: Data?) throws {
        guard (try? Data(contentsOf: url)) == original else {
            throw ApplicationEditingError.invalid("This file changed while the editor was open. Close and reopen the editor before saving.")
        }
    }

    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func profileDirectory(context: DiscoveryContext) -> URL {
        context.environment["THRESHOLD_PROFILES"].map(context.expand)
            ?? FrameworkCatalog.runner(context: context).deletingLastPathComponent().deletingLastPathComponent().appending(path: "profiles")
    }

    public static func validateProfile(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? String == "threshold-runtime/app-profile-1",
              let id = object["id"] as? String, !id.isEmpty,
              let title = object["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let guest = object["guest"] as? String, ["linux", "android"].contains(guest),
              let components = object["components"] as? [String: String], components["host"] != nil,
              let section = object[guest] as? [String: Any] else {
            throw ApplicationEditingError.invalid("A runtime profile needs its schema, ID, title, guest, host component and guest settings.")
        }
        for key in guest == "android" ? ["pin", "app_root", "apk", "loader"] : ["root", "libs"] {
            guard let value = section[key] as? String, !value.isEmpty else {
                throw ApplicationEditingError.invalid("Missing \(guest).\(key).")
            }
        }
        return object
    }

    public static func saveProfile(_ data: Data, to url: URL, original: Data) throws {
        let object = try validateProfile(data)
        let previous = try validateProfile(original)
        guard object["id"] as? String == previous["id"] as? String else {
            throw ApplicationEditingError.invalid("The runtime profile ID cannot be changed.")
        }
        try checkUnchanged(url, original: original)
        try write(data, to: url)
    }

    /// Convenience entry point for APKs that need no additional content selection.
    public static func importAPK(_ apk: URL, context: DiscoveryContext) throws {
        let inspection = try QuestAPKImport.inspect(apk, context: context)
        try QuestAPKImport.prepare(apk, inspection: inspection, context: context)
    }
}
