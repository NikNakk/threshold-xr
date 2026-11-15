import Foundation

/// A game macOS Steam has installed and that supports VR.
public struct SteamGame: Sendable, Hashable, Identifiable {
    public var appID: UInt32
    public var name: String
    /// `steamapps/common/<installdir>` in the library holding it.
    public var installFolder: URL
    /// Whether it has a launch entry of type `vr` (Steam's "Launch in VR").
    public var hasVRLaunch: Bool
    /// Steam's library artwork, when cached.
    public var coverArt: URL?

    public var id: UInt32 { appID }

    public init(appID: UInt32, name: String, installFolder: URL, hasVRLaunch: Bool, coverArt: URL? = nil) {
        self.appID = appID
        self.name = name
        self.installFolder = installFolder
        self.hasVRLaunch = hasVRLaunch
        self.coverArt = coverArt
    }
}

/// Reads macOS Steam's own files, offline and without signing in:
/// `steamapps/libraryfolders.vdf`, each library's `appmanifest_<appid>.acf`
/// for what is installed, and `appcache/appinfo.vdf` for VR support. Games
/// installed through Steam Play (macos-wine-xr) are ordinary installs here.
public enum SteamLibrary {
    /// Steamworks Common Redistributables and SteamVR: installed, never games.
    static let tools: Set<UInt32> = [228_980, 250_820]

    public static func root(context: DiscoveryContext) -> URL {
        context.home("Library/Application Support/Steam")
    }

    /// Installed VR games, by name.
    public static func installedVRGames(context: DiscoveryContext) throws -> [SteamGame] {
        let steam = root(context: context)
        let installed = installedApps(steam: steam)
        guard !installed.isEmpty else { return [] }
        let appInfo = try KeyValues.appInfo(
            Data(contentsOf: steam.appending(path: "appcache/appinfo.vdf"), options: .mappedIfSafe),
            apps: Set(installed.keys)
        )
        return installed.compactMap { appID, app -> SteamGame? in
            guard let info = appInfo[appID], isGame(info), isVR(info) else { return nil }
            let cover = steam.appending(path: "appcache/librarycache/\(appID)/library_600x900.jpg")
            return SteamGame(
                appID: appID,
                name: info["common"]?["name"]?.string ?? app.name,
                installFolder: app.folder,
                hasVRLaunch: launchEntries(info).contains { $0["type"]?.string?.lowercased() == "vr" },
                coverArt: FileProbe.exists(cover) ? cover : nil
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Fully installed apps (StateFlags has bit 4) whose folder exists, from every library.
    static func installedApps(steam: URL) -> [UInt32: (name: String, folder: URL)] {
        var libraries = [steam]
        if let text = try? String(contentsOf: steam.appending(path: "steamapps/libraryfolders.vdf"), encoding: .utf8),
           let folders = try? KeyValues.parse(text)["libraryfolders"] {
            for (_, library) in folders.children {
                if let path = library["path"]?.string { libraries.append(URL(fileURLWithPath: path)) }
            }
        }
        var apps: [UInt32: (name: String, folder: URL)] = [:]
        var seen = Set<String>()
        for library in libraries where seen.insert(library.standardizedFileURL.path).inserted {
            let steamapps = library.appending(path: "steamapps")
            for manifest in FileProbe.directoryContents(steamapps)
            where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                      let state = try? KeyValues.parse(text)["AppState"],
                      let appID = state["appid"]?.string.flatMap(UInt32.init),
                      !tools.contains(appID), apps[appID] == nil,
                      let flags = state["StateFlags"]?.string.flatMap(Int.init), flags & 4 != 0,
                      let installDir = state["installdir"]?.string, !installDir.isEmpty
                else { continue }
                let folder = steamapps.appending(path: "common/\(installDir)")
                guard FileProbe.isDirectory(folder) else { continue }
                apps[appID] = (state["name"]?.string ?? String(appID), folder)
            }
        }
        return apps
    }

    /// Steam's types game, application and demo; not DLC, tools or soundtracks.
    static func isGame(_ info: KeyValue) -> Bool {
        ["game", "application", "demo"].contains(info["common"]?["type"]?.string?.lowercased() ?? "")
    }

    /// OpenVR, OpenXR or VR-only support, or a VR launch entry (as macos-wine-xr's steam_games.is_vr).
    static func isVR(_ info: KeyValue) -> Bool {
        let common = info["common"]
        if ["openvrsupport", "openxrsupport", "onlyvrsupport"].contains(where: { common?[$0]?.string == "1" }) {
            return true
        }
        return launchEntries(info).contains { $0["type"]?.string?.lowercased() == "vr" }
    }

    static func launchEntries(_ info: KeyValue) -> [KeyValue] {
        info["config"]?["launch"]?.children.sorted { $0.key < $1.key }.map(\.value) ?? []
    }
}
