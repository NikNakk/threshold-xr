import Foundation

enum ShellOverlayButton: String, Codable, Sendable {
    case home
    case menu
    case options
}

struct ShellSettings: Sendable {
    static let defaultHomeWidthMeters: Float = 3.0
    static let homeWidthRange: ClosedRange<Float> = 1.5...5.0

    var systemOverlayButton: ShellOverlayButton = .home
    var steamGames: SteamGamesConfiguration = .default
    /// Width of the Home panel at the standard 1.8 m viewing distance.
    var homeWidthMeters: Float = defaultHomeWidthMeters

    private struct Document: Codable {
        var systemOverlayButton: ShellOverlayButton?
        /// macos-wine-xr's tools/steam_games/steam_games.py.
        var steamGamesTool: String?
        /// The rig's run-windows-game.zsh.
        var windowsGameRunner: String?
        /// Home panel width in metres (1.5–5.0; default 3.0).
        var homeWidthMeters: Float?
    }

    static var settingsURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return base
            .appendingPathComponent("SwiftXRShell", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    static func load() throws -> ShellSettings {
        let url = settingsURL
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: url.path) {
            let data = try JSONEncoder.prettyPrinted.encode(
                Document(systemOverlayButton: .home)
            )
            try data.write(to: url, options: .atomic)
            return ShellSettings()
        }

        let document = try JSONDecoder().decode(
            Document.self,
            from: Data(contentsOf: url)
        )
        var steamGames = SteamGamesConfiguration.default
        if let path = document.steamGamesTool, !path.isEmpty {
            steamGames.toolURL = expandedFileURL(path)
        }
        if let path = document.windowsGameRunner, !path.isEmpty {
            steamGames.runnerURL = expandedFileURL(path)
        }
        return ShellSettings(
            systemOverlayButton: document.systemOverlayButton ?? .home,
            steamGames: steamGames,
            homeWidthMeters: clampedHomeWidth(document.homeWidthMeters)
        )
    }

    static func clampedHomeWidth(_ value: Float?) -> Float {
        guard let value, value.isFinite else { return defaultHomeWidthMeters }
        return min(max(value, homeWidthRange.lowerBound), homeWidthRange.upperBound)
    }

    /// The Home panel width: SWIFTXR_HOME_WIDTH_METERS, else settings.json's
    /// homeWidthMeters, else the default. Read once at startup.
    static let homeWidthMeters: Float = {
        if let text = ProcessInfo.processInfo.environment["SWIFTXR_HOME_WIDTH_METERS"], let value = Float(text) {
            return clampedHomeWidth(value)
        }
        return (try? load().homeWidthMeters) ?? defaultHomeWidthMeters
    }()

    private static func expandedFileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
