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
        let runner = try home.write("rt/bin/threshold-run", "#!/bin/sh\ntrap '' TERM\nsleep 30\n", executable: true)
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
        let started = Date()
        coordinator.stop(id)
        let record = try await waitUntilEnded(coordinator, id)
        #expect(Date().timeIntervalSince(started) >= 0.9)
        #expect(record.exit == .signaled(SIGKILL))
    }
}
