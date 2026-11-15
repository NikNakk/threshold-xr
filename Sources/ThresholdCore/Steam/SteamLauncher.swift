import AppKit
import Darwin
import Foundation

/// A Steam game started through the running macOS Steam client, as Play in
/// Steam's library does: Steam applies Steam Play (macos-wine-xr's
/// compatibility tool), the game's Launch Options and its first-run setup.
/// Steam must already be running from Steam Play.app; opening a `steam://`
/// URL otherwise starts plain Steam.app, which has Steam Play off.
public final class SteamGameProcess: LaunchedProcess, @unchecked Sendable {
    /// The top process of the game: Steam's compatibility tool
    /// (`mwxr-steam-play`) for a Steam Play game, or the game itself.
    private let root: ProcessTable.Entry
    private let exit = ExitBox()
    private var source: DispatchSourceProcess?
    public let logURL: URL? = nil

    public var pid: Int32 { root.pid }

    private init(root: ProcessTable.Entry) {
        self.root = root
        let source = DispatchSource.makeProcessSource(identifier: root.pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [exit] in exit.finish(.unknown) }
        source.resume()
        self.source = source
        if Darwin.kill(root.pid, 0) != 0 { exit.finish(.unknown) }
    }

    deinit { source?.cancel() }

    /// How long Steam may take to start the game (an update or first-run setup can come first).
    static let startTimeout: TimeInterval = 120

    static func start(_ target: LaunchTarget, startTimeout: TimeInterval = startTimeout) async throws -> SteamGameProcess {
        guard let folder = target.steamInstallFolder else {
            throw LaunchError.failedToStart("\(target.title) has no Steam install folder.")
        }
        guard ProcessTable.isRunning(named: SteamLauncher.clientProcessName) else {
            throw LaunchError.blocked(SteamLauncher.notRunningMessage)
        }
        let before = Set(SteamLauncher.gameProcesses(in: folder).map(\.pid))
        guard before.isEmpty else {
            throw LaunchError.blocked("\(target.title) is already running.")
        }
        let opened = await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(target.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                continuation.resume(returning: error)
            }
        }
        if let opened {
            throw LaunchError.failedToStart("Steam could not start \(target.title): \(opened.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(startTimeout)
        while Date() < deadline {
            if let root = SteamLauncher.gameProcesses(in: folder).first {
                return SteamGameProcess(root: root)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LaunchError.failedToStart(
            "Steam did not start \(target.title) within \(Int(startTimeout)) s. Check Steam for an update, a launch choice or an error."
        )
    }

    public func waitForExit() async -> ProcessExit { await exit.wait() }

    /// SIGTERM to the game's runner and the top process. The rig's runner closes
    /// the game on SIGTERM (stop_game in run-windows-game.zsh); a shell such as
    /// mwxr-steam-play alone would exit and leave it running.
    public func requestStop() {
        let children = ProcessTable.descendants(of: root.pid).filter { $0.parent == root.pid }
        for child in children { Darwin.kill(child.pid, SIGTERM) }
        Darwin.kill(root.pid, SIGTERM)
    }

    public func forceStop() {
        for process in ProcessTable.descendants(of: root.pid).reversed() { Darwin.kill(process.pid, SIGKILL) }
        Darwin.kill(root.pid, SIGKILL)
    }
}

public enum SteamLauncher {
    static let clientProcessName = "steam_osx"
    static let notRunningMessage = "Steam is not running. Start it from Steam Play.app (~/Applications), so Steam Play is on."

    /// `steam://launch/<appid>/VR` for games with a VR launch entry (Steam's
    /// "Launch in VR"), otherwise `steam://rungameid/<appid>`.
    public static func url(for game: SteamGame) -> URL {
        URL(string: game.hasVRLaunch ? "steam://launch/\(game.appID)/VR" : "steam://rungameid/\(game.appID)")!
    }

    /// The top processes of a game: those with an argument inside its install
    /// folder that have no such process among their ancestors.
    static func gameProcesses(in folder: URL, table: [ProcessTable.Entry] = ProcessTable.all()) -> [ProcessTable.Entry] {
        let prefix = folder.standardizedFileURL.path + "/"
        let matching = table.filter { entry in entry.arguments.contains { $0.hasPrefix(prefix) } }
        let pids = Set(matching.map(\.pid))
        let parents = Dictionary(table.map { ($0.pid, $0.parent) }, uniquingKeysWith: { first, _ in first })
        func hasMatchingAncestor(_ entry: ProcessTable.Entry) -> Bool {
            var pid = entry.parent
            var steps = 0
            while pid > 1, steps < 64 {
                if pids.contains(pid) { return true }
                pid = parents[pid] ?? 0
                steps += 1
            }
            return false
        }
        return matching.filter { !hasMatchingAncestor($0) }.sorted { $0.pid < $1.pid }
    }
}
