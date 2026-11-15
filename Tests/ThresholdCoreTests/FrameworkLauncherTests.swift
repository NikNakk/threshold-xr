import Darwin
import Foundation
import Testing
@testable import ThresholdCore

/// A stand-in for threshold-runtime's bin/threshold-run: `--list --json` prints list.json next to
/// it; `<id> ... --status-file PATH` writes the status events threshold-run would.
private let fakeRunner = """
#!/bin/sh
here=$(dirname "$0")
if [ "$1" = --list ]; then cat "$here/list.json"; exit 0; fi
id=$1; shift; status=""
while [ $# -gt 0 ]; do [ "$1" = --status-file ] && status=$2; shift; done
echo "runner started $id"
printf '{"event":"started","time":1,"pid":1,"run":"/tmp/run-%s","log":"/tmp/run-%s/game.log"}\\n' "$id" "$id" >> "$status"
case "$id" in
  crashy) printf '{"event":"exited","time":2,"exit_code":139,"signal":11,"crashed":true}\\n' >> "$status"; exit 139 ;;
  faulty) printf '{"event":"exited","time":2,"exit_code":0,"signal":null,"crashed":true}\\n' >> "$status"; exit 0 ;;
  *) printf '{"event":"exited","time":2,"exit_code":0,"signal":null,"crashed":false}\\n' >> "$status"; exit 0 ;;
esac
"""

private let listing = """
[
  {"id": "alyx", "title": "Half-Life: Alyx", "subtitle": "Native Linux ARM64", "guest": "linux",
   "openxr_application_name": "alyx_host", "system_image": "visionpro", "path": "/p/alyx.json",
   "component_sets": ["previous"],
   "components": {"host": {"path": "/b/alyx_host", "exists": true}, "xrizer": {"path": "/b/libxrizer.dylib", "exists": true}}},
  {"id": "openbrush", "title": "Open Brush", "subtitle": null, "guest": "android", "system_image": null,
   "path": "/p/openbrush.json", "component_sets": [],
   "components": {"host": {"path": "/b/quest_host", "exists": false}}}
]
"""

private func runtime(_ home: TemporaryDirectory) throws -> DiscoveryContext {
    try home.write("rt/bin/threshold-run", fakeRunner, executable: true)
    try home.write("rt/bin/list.json", listing)
    return home.context(environment: ["THRESHOLD_RUNTIME": home.url.appending(path: "rt").path, "PATH": "/usr/bin:/bin"])
}

private func profile(_ id: String, exists: Bool = true) throws -> FrameworkProfile {
    let json = """
    {"id": "\(id)", "title": "\(id)", "guest": "linux", "path": "/p/\(id).json",
     "components": {"host": {"path": "/b/alyx_host", "exists": \(exists)}}}
    """
    return try JSONDecoder().decode(FrameworkProfile.self, from: Data(json.utf8))
}

struct FrameworkCatalogTests {
    @Test func listsProfilesFromTheRunner() throws {
        let home = try TemporaryDirectory()
        let context = try runtime(home)
        let profiles = try FrameworkCatalog.load(context: context)
        #expect(profiles.map(\.id) == ["alyx", "openbrush"])
        #expect(profiles[0].openXRApplicationName == "alyx_host")
        #expect(profiles[0].hostProcessName == "alyx_host")
        #expect(profiles[0].missingComponents.isEmpty)
        #expect(profiles[1].missingComponents == ["host (/b/quest_host)"])
    }

    @Test func missingRunnerIsReported() throws {
        let home = try TemporaryDirectory()
        let context = home.context(environment: ["THRESHOLD_RUNTIME": home.url.appending(path: "none").path])
        #expect(throws: FrameworkCatalogError.self) { try FrameworkCatalog.load(context: context) }
    }

    @Test func targetRunsTheProfileThroughTheRunner() throws {
        let runner = URL(fileURLWithPath: "/rt/bin/threshold-run")
        let target = LaunchTarget(profile: try profile("alyx"), runner: runner)
        #expect(target.kind == .frameworkProfile)
        #expect(target.url == runner)
        #expect(target.arguments == ["alyx"])
        #expect(target.id == "threshold-runtime.alyx")
        #expect(target.processName == "alyx_host")
    }

    @Test func missingComponentsBlockTheLaunch() throws {
        let home = try TemporaryDirectory()
        let runner = try home.write("threshold-run", "#!/bin/sh\n", executable: true)
        let blocked = LaunchTarget(profile: try profile("alyx", exists: false), runner: runner)
        let issues = LaunchPreflight.check(blocked, monado: nil, alreadyRunning: false)
        #expect(issues.contains { $0.severity == .blocking && $0.message.contains("missing host") })
        let ready = LaunchTarget(profile: try profile("alyx"), runner: runner)
        #expect(LaunchPreflight.canLaunch(LaunchPreflight.check(ready, monado: nil, alreadyRunning: false)))
    }
}

struct FrameworkStatusTests {
    func event(_ json: String) throws -> FrameworkStatus.Event {
        try JSONDecoder().decode(FrameworkStatus.Event.self, from: Data(json.utf8))
    }

    @Test func mapsTheAppsExit() throws {
        let fallback = ProcessExit.exited(99)
        #expect(FrameworkStatus.exit(from: [], runnerExit: fallback) == fallback)
        #expect(FrameworkStatus.exit(from: [try event(#"{"event":"exited","exit_code":0,"crashed":false}"#)],
                                     runnerExit: fallback) == .exited(0))
        #expect(FrameworkStatus.exit(from: [try event(#"{"event":"exited","exit_code":139,"signal":11,"crashed":true}"#)],
                                     runnerExit: fallback) == .signaled(SIGSEGV))
        #expect(FrameworkStatus.exit(from: [try event(#"{"event":"exited","exit_code":0,"crashed":true}"#)],
                                     runnerExit: fallback) == .signaled(SIGABRT))
        #expect(FrameworkStatus.exit(from: [try event(#"{"event":"exited","exit_code":124,"stopped_by":"timeout","crashed":false}"#)],
                                     runnerExit: fallback) == .exited(124))
    }
}

@MainActor
struct FrameworkLaunchTests {
    func coordinator(_ home: TemporaryDirectory) -> LaunchCoordinator {
        LaunchCoordinator(
            launcher: DirectLauncher(environment: ["PATH": "/usr/bin:/bin"]),
            crashFinder: CrashReportFinder(directories: [home.url.appending(path: "reports")]),
            logDirectory: home.url.appending(path: "logs"),
            stopGracePeriod: .milliseconds(300),
            crashReportDelay: .milliseconds(50)
        )
    }

    func target(_ id: String, _ home: TemporaryDirectory) throws -> LaunchTarget {
        let context = try runtime(home)
        return LaunchTarget(profile: try profile(id), runner: FrameworkCatalog.runner(context: context))
    }

    @Test func cleanRunExits() async throws {
        let home = try TemporaryDirectory()
        let coordinator = coordinator(home)
        let id = try await coordinator.launch(try target("alyx", home), monado: nil)
        let record = try await waitUntilEnded(coordinator, id)
        #expect(record.phase == .exited)
        #expect(record.exit == .exited(0))
        let log = try String(contentsOf: try #require(record.logURL), encoding: .utf8)
        #expect(log.contains("runner started alyx"))
    }

    @Test func crashInTheGuestIsACrash() async throws {
        let home = try TemporaryDirectory()
        let coordinator = coordinator(home)
        let crashed = try await waitUntilEnded(coordinator, try await coordinator.launch(try target("crashy", home), monado: nil))
        #expect(crashed.phase == .crashed)
        #expect(crashed.exit == .signaled(SIGSEGV))
        let faulted = try await waitUntilEnded(coordinator, try await coordinator.launch(try target("faulty", home), monado: nil))
        #expect(faulted.phase == .crashed)
    }
}

@MainActor
struct ApplicationCatalogTests {
    @Test func listsTheShellCatalogThenFrameworkApplications() throws {
        let home = try TemporaryDirectory()
        var context = try runtime(home)
        try home.write("apps.json", #"[{"id": " paint ", "title": "Paint", "path": "~/Paint.app"}]"#)
        context.environment["SWIFTXR_SHELL_APPS"] = home.url.appending(path: "apps.json").path
        let catalog = ApplicationCatalog.load(context: context)
        #expect(catalog.problems.isEmpty)
        #expect(catalog.targets.map(\.id) == ["paint", "threshold-runtime.alyx", "threshold-runtime.openbrush"])
        #expect(catalog.targets[0].kind == .appBundle)
        #expect(catalog.targets[1].stopGracePeriod == 10)
        #expect(catalog.targets[1].clientTimeout == 120)
        #expect(catalog.targets[2].unavailableReasons == ["missing host (/b/quest_host)"])
    }

    @Test func oneUnreadableSourceKeepsTheOther() throws {
        let home = try TemporaryDirectory()
        var context = try runtime(home)
        try home.write("apps.json", #"[{"id": "a", "title": "A", "path": "/a"}, {"id": "a", "title": "B", "path": "/b"}]"#)
        context.environment["SWIFTXR_SHELL_APPS"] = home.url.appending(path: "apps.json").path
        let catalog = ApplicationCatalog.load(context: context)
        #expect(catalog.problem(.shellCatalog) == ShellAppCatalogError.duplicateID("a").localizedDescription)
        #expect(catalog.problem(.framework) == nil)
        #expect(catalog.targets.count == 2)

        context.environment["THRESHOLD_RUNTIME"] = home.url.appending(path: "none").path
        context.environment["SWIFTXR_SHELL_APPS"] = home.url.appending(path: "missing.json").path
        let noRuntime = ApplicationCatalog.load(context: context)
        #expect(noRuntime.targets.isEmpty)
        #expect(noRuntime.problem(.framework) != nil)
        #expect(noRuntime.problem(.shellCatalog) == nil)
    }

    @Test func invalidEntriesAreRejected() {
        #expect(throws: ShellAppCatalogError.emptyTitle("x")) {
            try ShellAppCatalog.decode(Data(#"[{"id": "x", "title": " ", "path": "/x"}]"#.utf8))
        }
        #expect(throws: ShellAppCatalogError.emptyID) {
            try ShellAppCatalog.decode(Data(#"[{"id": "", "title": "X", "path": "/x"}]"#.utf8))
        }
    }

    @Test func stopWaitsForTheFrameworkRunner() async throws {
        let home = try TemporaryDirectory()
        // Ignores SIGTERM, as threshold-run does while it stops the app.
        let ready = home.url.appending(path: "ready")
        let runner = try home.write("rt/bin/threshold-run", "#!/bin/sh\ntrap '' TERM\ntouch '\(ready.path)'\nsleep 30\n", executable: true)
        var target = LaunchTarget(profile: try profile("alyx"), runner: runner)
        target.stopGracePeriod = 1
        let coordinator = LaunchCoordinator(
            launcher: DirectLauncher(environment: ["PATH": "/usr/bin:/bin"]),
            crashFinder: CrashReportFinder(directories: []),
            logDirectory: home.url.appending(path: "logs"),
            stopGracePeriod: .milliseconds(100),
            crashReportDelay: .milliseconds(10)
        )
        let id = try await coordinator.launch(target, monado: nil)
        while !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(20)) }
        let started = Date()
        coordinator.stop(id)
        let record = try await waitUntilEnded(coordinator, id)
        #expect(Date().timeIntervalSince(started) >= 0.9)
        #expect(record.exit == .signaled(SIGKILL))
    }
}

struct SteamLibraryTests {
    private func manifest(_ appID: UInt32, _ name: String, _ dir: String, flags: Int = 4) -> String {
        """
        "AppState"
        {
        \t"appid"\t\t"\(appID)"
        \t"name"\t\t"\(name)"
        \t"StateFlags"\t\t"\(flags)"
        \t"installdir"\t\t"\(dir)"
        }
        """
    }

    /// appinfo.vdf format 29: header, app records, then the string table.
    private func appInfo(_ apps: [(UInt32, [(String, Any)])]) -> Data {
        var strings: [String] = []
        func index(_ s: String) -> Int32 {
            if let i = strings.firstIndex(of: s) { return Int32(i) }
            strings.append(s); return Int32(strings.count - 1)
        }
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func object(_ pairs: [(String, Any)]) -> [UInt8] {
            var out: [UInt8] = []
            for (key, value) in pairs {
                if let s = value as? String { out += [0x01] + le(index(key)) + Array(s.utf8) + [0] }
                else if let i = value as? Int32 { out += [0x02] + le(index(key)) + le(i) }
                else if let o = value as? [(String, Any)] { out += [0x00] + le(index(key)) + object(o) }
            }
            return out + [0x08]
        }
        var body: [UInt8] = []
        for (appID, info) in apps {
            let kv = object([("appinfo", info)])
            let record = [UInt8](repeating: 0, count: 4 + 4 + 8 + 20 + 4 + 20) + kv
            body += le(appID) + le(UInt32(record.count)) + record
        }
        body += le(UInt32(0))
        let table = 16 + body.count
        var data = le(UInt32(0x0756_4429)) + le(UInt32(1)) + le(Int64(table)) + body
        data += le(UInt32(strings.count))
        for s in strings { data += Array(s.utf8) + [0] }
        return Data(data)
    }

    @Test func listsInstalledVRGamesFromEveryLibrary() throws {
        let home = try TemporaryDirectory()
        let steam = "Library/Application Support/Steam"
        let other = home.url.appending(path: "SSD/SteamLibrary")
        try home.write("\(steam)/steamapps/libraryfolders.vdf", """
        "libraryfolders"
        {
        \t"0" { "path" "\(home.url.appending(path: steam).path)" }
        \t"1" { "path" "\(other.path)" }
        }
        """)
        try home.write("\(steam)/steamapps/appmanifest_1256230.acf", manifest(1256230, "Hyperbolica", "Hyperbolica"))
        try home.write("\(steam)/steamapps/common/Hyperbolica/game.exe", "")
        try home.write("\(steam)/steamapps/appmanifest_220.acf", manifest(220, "Half-Life 2", "Half-Life 2"))
        try home.write("\(steam)/steamapps/common/Half-Life 2/hl2", "")
        try home.write("\(steam)/steamapps/appmanifest_250820.acf", manifest(250820, "SteamVR", "SteamVR"))
        try home.write("\(steam)/steamapps/common/SteamVR/x", "")
        try home.write("SSD/SteamLibrary/steamapps/appmanifest_348250.acf", manifest(348250, "Google Earth VR", "EarthVR"))
        try home.write("SSD/SteamLibrary/steamapps/common/EarthVR/Earth.exe", "")
        try home.write("SSD/SteamLibrary/steamapps/appmanifest_826540.acf", manifest(826540, "Audio Trip", "AudioTrip", flags: 1028))
        try home.write("SSD/SteamLibrary/steamapps/appmanifest_9.acf", manifest(9, "Not installed", "Gone", flags: 2))
        try home.write("SSD/SteamLibrary/steamapps/common/AudioTrip/AT.exe", "")
        let data = appInfo([
            (220, [("common", [("type", "Game"), ("name", "Half-Life 2")] as [(String, Any)])]),
            (250820, [("common", [("type", "Tool"), ("openvrsupport", "1")] as [(String, Any)])]),
            (348250, [("common", [("type", "Application"), ("name", "Google Earth VR"), ("openvrsupport", Int32(1))] as [(String, Any)])]),
            (826540, [("common", [("type", "Game"), ("name", "Audio Trip"), ("onlyvrsupport", "1")] as [(String, Any)])]),
            (1256230, [
                ("common", [("type", "game"), ("name", "Hyperbolica")] as [(String, Any)]),
                ("config", [("launch", [
                    ("0", [("executable", "Hyperbolica.exe")] as [(String, Any)]),
                    ("1", [("executable", "Hyperbolica.exe"), ("arguments", "startXR"), ("type", "vr")] as [(String, Any)]),
                ] as [(String, Any)])] as [(String, Any)]),
            ]),
        ])
        try FileManager.default.createDirectory(at: home.url.appending(path: "\(steam)/appcache"), withIntermediateDirectories: true)
        try data.write(to: home.url.appending(path: "\(steam)/appcache/appinfo.vdf"))

        let games = try SteamLibrary.installedVRGames(context: home.context())
        try #require(games.count == 3)
        #expect(games.map(\.name) == ["Audio Trip", "Google Earth VR", "Hyperbolica"])
        #expect(games.map(\.hasVRLaunch) == [false, false, true])
        #expect(games[1].installFolder.path.hasSuffix("SSD/SteamLibrary/steamapps/common/EarthVR"))
        #expect(SteamLauncher.url(for: games[2]).absoluteString == "steam://launch/1256230/VR")
        #expect(SteamLauncher.url(for: games[0]).absoluteString == "steam://rungameid/826540")

        let target = LaunchTarget(steamGame: games[2])
        #expect(target.id == "steam.1256230")
        #expect(target.kind == .steamGame)
        #expect(target.stopGracePeriod == 20)
    }

    @Test func noSteamIsAnEmptyLibrary() throws {
        let home = try TemporaryDirectory()
        #expect(try SteamLibrary.installedVRGames(context: home.context()).isEmpty)
    }

    @Test func findsTheTopProcessOfAGame() {
        let folder = URL(fileURLWithPath: "/S/steamapps/common/Game")
        let table: [ProcessTable.Entry] = [
            .init(pid: 10, parent: 1, arguments: ["steam_osx"]),
            .init(pid: 20, parent: 10, arguments: ["/bin/sh", "/t/mwxr-steam-play", "waitforexitandrun", "/S/steamapps/common/Game/g.exe"]),
            .init(pid: 30, parent: 20, arguments: ["zsh", "run-windows-game.zsh", "1"]),
            .init(pid: 40, parent: 30, arguments: ["wine", "/S/steamapps/common/Game/g.exe"]),
            .init(pid: 50, parent: 1, arguments: ["/S/steamapps/common/GameTwo/x"]),
        ]
        #expect(SteamLauncher.gameProcesses(in: folder, table: table).map(\.pid) == [20])
        #expect(ProcessTable.descendants(of: 20, in: table).map(\.pid) == [30, 40])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["THRESHOLD_TEST_REAL_STEAM"] == "1"))
    func readsThisMachinesSteam() throws {
        let games = try SteamLibrary.installedVRGames(context: .current())
        for game in games { print("steam \(game.appID) \(game.name) vrLaunch=\(game.hasVRLaunch) \(game.installFolder.path)") }
        #expect(!games.isEmpty)
    }
}
