import Foundation

/// Runtime-owned inspection contract. Engine detection does not imply headset compatibility.
public struct QuestAPKInspection: Sendable, Decodable {
    public struct Dependency: Sendable, Decodable {
        public var name: String
        public var available: Bool
    }
    public struct Game: Sendable, Decodable, Identifiable {
        public var id: String
        public var title: String
        public var contentFolders: [String]
    }
    public var schema: String
    public var title: String
    public var package: String
    public var version: String
    public var engine: String
    public var abis: [String]
    public var activities: [String]
    public var libraries: [String]
    public var xrApis: [String]
    public var metaPlatformSdkPresent: Bool
    public var adapter: String?
    public var sha256: String
    public var supported: Bool
    public var problems: [String]
    public var warnings: [String]
    public var games: [Game]
    public var dependencies: [Dependency]
}

/// Threshold XR presents the runtime's capabilities and publishes its prepared profile.
/// APK inspection, engine rules, pins and launch defaults all belong to threshold-runtime.
public enum QuestAPKImport {
    private static let inspectionSchema = "threshold-runtime/apk-inspection-1"
    private static let preparationSchema = "threshold-runtime/apk-preparation-1"

    public static func inspect(_ apk: URL, context: DiscoveryContext) throws -> QuestAPKInspection {
        let data = try run(["--inspect", "--apk", apk.path], context: context)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let inspection = try decoder.decode(QuestAPKInspection.self, from: data)
        guard inspection.schema == inspectionSchema else {
            throw ApplicationEditingError.invalid("Unsupported APK inspection format. Update Threshold XR and threshold-runtime together.")
        }
        return inspection
    }

    public static func prepare(_ apk: URL, inspection: QuestAPKInspection, game: String? = nil,
                               content: URL? = nil, portalContent: URL? = nil, context: DiscoveryContext) throws {
        guard inspection.schema == inspectionSchema, inspection.supported else {
            throw ApplicationEditingError.invalid(inspection.problems.joined(separator: "\n"))
        }
        let id = "quest-" + UUID().uuidString.lowercased()
        let folder = context.home("Library/Application Support/ThresholdXR/QuestApps").appending(path: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: folder) } }
        let prepared = folder.appending(path: "prepared")
        let overrides = folder.appending(path: "components.json")
        var components: [String: String] = [:]
        if let profiles = try? FrameworkCatalog.load(context: context) {
            let android = profiles.filter { $0.guest == "android" }
            let existing = android.first { $0.missingComponents.isEmpty } ?? android.first
            if let existing {
                for (name, component) in existing.components { components[name] = component.path }
            }
            // Offer all configured dependencies; the runtime adapter decides which ones it needs.
            for profile in android {
                for (name, component) in profile.components where components[name] == nil {
                    components[name] = component.path
                }
            }
        }
        try JSONEncoder().encode(components).write(to: overrides)
        var arguments = ["--apk", apk.path, "--output", prepared.path, "--id", id,
                         "--expected-sha256", inspection.sha256, "--components-json", overrides.path]
        if let game { arguments += ["--game", game] }
        if let content { arguments += ["--content", content.path] }
        if let portalContent { arguments += ["--portal-content", portalContent.path] }
        let data = try run(arguments, context: context)
        struct Receipt: Decodable {
            var schema: String
            var profile: String
            var sha256: String
        }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        let profileURL = prepared.appending(path: "profile.json")
        guard receipt.schema == preparationSchema, receipt.profile == profileURL.path,
              receipt.sha256 == inspection.sha256 else {
            throw ApplicationEditingError.invalid("threshold-runtime returned an inconsistent preparation receipt; no profile was added.")
        }
        let profile = try Data(contentsOf: profileURL)
        let object = try ApplicationEditing.validateProfile(profile)
        guard object["id"] as? String == id else {
            throw ApplicationEditingError.invalid("The prepared profile has an unexpected ID; no profile was added.")
        }
        let destination = ApplicationEditing.profileDirectory(context: context).appending(path: id + ".json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try profile.write(to: destination, options: .withoutOverwriting)
        published = true
    }

    /// Files for stdout/stderr avoid pipe deadlocks during long APK decoding operations.
    private static func run(_ arguments: [String], context: DiscoveryContext) throws -> Data {
        let runtime = FrameworkCatalog.runner(context: context).deletingLastPathComponent().deletingLastPathComponent()
        let tool = runtime.appending(path: "android/tools/quest_import.py")
        guard FileProbe.exists(tool) else {
            throw ApplicationEditingError.invalid("Update threshold-runtime to a version with android/tools/quest_import.py to import Quest APKs.")
        }
        let temp = FileManager.default.temporaryDirectory.appending(path: "threshold-quest-\(UUID())")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let outputURL = temp.appending(path: "output.json"), errorsURL = temp.appending(path: "errors.log")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errorsURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL), errors = try FileHandle(forWritingTo: errorsURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", tool.path] + arguments
        var environment = context.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errorsURL, encoding: .utf8)) ?? "Quest preparation failed."
            throw ApplicationEditingError.invalid(String(detail.suffix(6000)))
        }
        return try Data(contentsOf: outputURL)
    }
}
