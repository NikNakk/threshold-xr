import Foundation
import Testing
@testable import ThresholdCore

/// A Monado status from the controller with fake probes.
func monadoStatus(
    in home: TemporaryDirectory,
    running: Bool,
    connections: Int = 0,
    clients: [MonadoClientInfo]? = nil,
    loaded: Bool = true
) async throws -> MonadoStatus {
    _ = try makeMonadoInstall(in: home, environment: ["IPC_EXIT_WHEN_IDLE": "1"])
    let output = running ? launchctlPrintRunning : launchctlPrintIdle
    let runner = FakeRunner { arguments in
        if arguments.first == "print" {
            return loaded ? CommandResult(exitCode: 0, standardOutput: output) : CommandResult(exitCode: 113, standardError: "Could not find service")
        }
        return CommandResult(exitCode: 1)
    }
    let socket = home.url.appending(path: "Library/Caches/monado/monado_comp_ipc").path
    let querier = clients.map { FixedQuerier(clients: $0) }
    return await MonadoController(
        context: home.context(), runner: runner,
        sockets: FakeSockets(summary: running ? ProcessSocketSummary(listeningPaths: [socket], connectedCount: connections) : nil),
        usb: FakeUSB(list: []), querier: querier ?? FixedQuerier(clients: [])
    ).refresh()
}

struct FixedQuerier: RuntimeQuerying {
    var clients: [MonadoClientInfo]
    func snapshot(libmonado: URL) throws -> MonadoRuntimeSnapshot {
        MonadoRuntimeSnapshot(apiVersion: "1.8.0", clients: clients, devices: [], takenAt: Date())
    }
}

@MainActor
func waitUntilEnded(_ coordinator: LaunchCoordinator, _ id: UUID, timeout: Duration = .seconds(10)) async throws -> LaunchRecord {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if let record = coordinator.records.first(where: { $0.id == id }), !record.phase.isActive,
           record.endedAt != nil {
            // Allow the crash-report check to complete.
            try await Task.sleep(for: .milliseconds(150))
            return coordinator.records.first { $0.id == id }!
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("launch did not end in time")
    return coordinator.records.first { $0.id == id }!
}

@Suite("Launch preflight")
struct LaunchPreflightTests {
    @Test func blocksMissingOrNonExecutableTargets() throws {
        let home = try TemporaryDirectory()
        let missing = LaunchTarget(id: "a", title: "A", url: home.url.appending(path: "nope"))
        #expect(!LaunchPreflight.canLaunch(LaunchPreflight.check(missing, monado: nil, alreadyRunning: false)))

        let plain = try home.write("tool", "data")
        let notExecutable = LaunchTarget(id: "b", title: "B", url: plain)
        let issues = LaunchPreflight.check(notExecutable, monado: nil, alreadyRunning: false)
        #expect(issues.contains { $0.severity == .blocking && $0.message.contains("not executable") })

        let bundle = LaunchTarget(id: "c", title: "C", url: home.url.appending(path: "Missing.app"))
        #expect(bundle.kind == .appBundle)
        #expect(!LaunchPreflight.canLaunch(LaunchPreflight.check(bundle, monado: nil, alreadyRunning: false)))
    }

    @Test func blocksSecondCopy() throws {
        let home = try TemporaryDirectory()
        let script = try home.write("run.sh", "#!/bin/sh\n", executable: true)
        let target = LaunchTarget(id: "a", title: "A", url: script)
        #expect(LaunchPreflight.canLaunch(LaunchPreflight.check(target, monado: nil, alreadyRunning: false)))
        #expect(!LaunchPreflight.canLaunch(LaunchPreflight.check(target, monado: nil, alreadyRunning: true)))
    }

    @Test func warnsWhenMonadoCannotStartOnDemand() async throws {
        let home = try TemporaryDirectory()
        let script = try home.write("run.sh", "#!/bin/sh\n", executable: true)
        let status = try await monadoStatus(in: home, running: false, loaded: false)
        let issues = LaunchPreflight.check(LaunchTarget(id: "a", title: "A", url: script), monado: status, alreadyRunning: false)
        #expect(LaunchPreflight.canLaunch(issues), "warnings do not block")
        #expect(issues.contains { $0.severity == .warning && $0.message.contains("not loaded") })
        #expect(issues.contains { $0.severity == .info && $0.message.contains("headset") })
    }

    @Test func respectsAppSelectedRuntime() throws {
        let home = try TemporaryDirectory()
        let script = try home.write("run.sh", "#!/bin/sh\n", executable: true)
        let target = LaunchTarget(id: "a", title: "A", url: script, environment: ["XR_RUNTIME_JSON": "/x.json"])
        let issues = LaunchPreflight.check(target, monado: nil, alreadyRunning: false)
        #expect(issues == [LaunchIssue(.info, "This app selects its own OpenXR runtime manifest (XR_RUNTIME_JSON).")])
    }

    @Test func buildsTargetsFromThresholdHomeCatalog() throws {
        let home = try TemporaryDirectory()
        try home.write("Apps/Paint.app/Contents/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>PaintBin</string></dict></plist>
        """)
        let entry = ShellAppEntry(id: "paint", title: "Paint", subtitle: nil, systemImage: nil,
                                  path: "~/Apps/Paint.app", arguments: ["-v"], environment: ["A": "1"],
                                  openXRApplicationName: "Open Paint")
        let target = LaunchTarget(entry: entry, context: home.context())
        #expect(target.kind == .appBundle)
        #expect(target.url.path == home.url.appending(path: "Apps/Paint.app").path)
        #expect(target.processName == "PaintBin")
        #expect(target.clientNameCandidates.contains("open paint"))
    }
}

@Suite("Launching and following processes")
@MainActor
struct LaunchCoordinatorTests {
    func coordinator(_ home: TemporaryDirectory, crashDirectory: URL? = nil) -> LaunchCoordinator {
        LaunchCoordinator(
            launcher: DirectLauncher(environment: ["PATH": "/usr/bin:/bin", "BASE": "from-session"]),
            crashFinder: CrashReportFinder(directories: [crashDirectory ?? home.url.appending(path: "reports")]),
            logDirectory: home.url.appending(path: "logs"),
            stopGracePeriod: .milliseconds(300),
            crashReportDelay: .milliseconds(50)
        )
    }

    @Test func cleanExitIsLoggedWithEnvironment() async throws {
        let home = try TemporaryDirectory()
        let script = try home.write("app.sh", "#!/bin/sh\necho \"hello $BASE $EXTRA $1\"\nexit 0\n", executable: true)
        let coordinator = coordinator(home)
        let target = LaunchTarget(id: "demo app", title: "Demo", url: script, arguments: ["arg1"], environment: ["EXTRA": "override"])
        let id = try await coordinator.launch(target, monado: nil)
        let record = try await waitUntilEnded(coordinator, id)

        #expect(record.phase == .exited)
        #expect(record.exit == .exited(0))
        #expect(record.pid != nil)
        let log = try String(contentsOf: try #require(record.logURL), encoding: .utf8)
        #expect(log.contains("hello from-session override arg1"))
        #expect(log.contains("# env EXTRA=override"))
        #expect(record.logURL?.deletingLastPathComponent().lastPathComponent == "demo_app")
    }

    @Test func nonZeroExitIsAFailure() async throws {
        let home = try TemporaryDirectory()
        let script = try home.write("app.sh", "#!/bin/sh\nexit 3\n", executable: true)
        let coordinator = coordinator(home)
        let id = try await coordinator.launch(LaunchTarget(id: "a", title: "A", url: script), monado: nil)
        #expect(try await waitUntilEnded(coordinator, id).phase == .failed("Exited with status 3."))
    }

    @Test func crashSignalIsACrash() async throws {
        let home = try TemporaryDirectory()
        let script = try home.write("app.sh", "#!/bin/sh\nkill -SEGV $$\n", executable: true)
        let coordinator = coordinator(home)
        let id = try await coordinator.launch(LaunchTarget(id: "a", title: "A", url: script), monado: nil)
        let record = try await waitUntilEnded(coordinator, id)
        #expect(record.phase == .crashed)
        #expect(record.exit == .signaled(SIGSEGV))
    }

    @Test func crashReportMarksLaunchAsCrashed() async throws {
        let home = try TemporaryDirectory()
        let reports = try home.mkdir("reports")
        let script = try home.write("crashy", "#!/bin/sh\necho x > \"$REPORTS/crashy-2026-11-07-120000.ips\"\nexit 0\n", executable: true)
        let coordinator = coordinator(home, crashDirectory: reports)
        let target = LaunchTarget(id: "c", title: "Crashy", url: script, environment: ["REPORTS": reports.path])
        let id = try await coordinator.launch(target, monado: nil)
        let record = try await waitUntilEnded(coordinator, id)
        #expect(record.phase == .crashed)
        #expect(record.crashReport?.lastPathComponent == "crashy-2026-11-07-120000.ips")
    }

    @Test func stopTerminatesAndIsNotAFailure() async throws {
        let home = try TemporaryDirectory()
        let script = try home.write("app.sh", "#!/bin/sh\nexec sleep 30\n", executable: true)
        let coordinator = coordinator(home)
        let id = try await coordinator.launch(LaunchTarget(id: "a", title: "A", url: script), monado: nil)
        #expect(coordinator.activeRecord(for: "a") != nil)
        await #expect(throws: LaunchError.self) {
            try await coordinator.launch(LaunchTarget(id: "a", title: "A", url: script), monado: nil)
        }
        coordinator.stop(id)
        let record = try await waitUntilEnded(coordinator, id)
        #expect(record.phase == .exited)
        #expect(record.stopRequested)
        #expect(record.exit == .signaled(SIGTERM))
    }

    @Test func stopForcesAProcessThatIgnoresSigterm() async throws {
        let home = try TemporaryDirectory()
        let ready = home.url.appending(path: "ready")
        let script = try home.write("app.sh", "#!/bin/sh\ntrap '' TERM\ntouch \"$READY\"\nwhile true; do sleep 0.05; done\n", executable: true)
        let coordinator = coordinator(home)
        let id = try await coordinator.launch(
            LaunchTarget(id: "a", title: "A", url: script, environment: ["READY": ready.path]), monado: nil)
        // Stop only once the script has installed its SIGTERM trap.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        coordinator.stop(id)
        let record = try await waitUntilEnded(coordinator, id)
        #expect(record.exit == .signaled(SIGKILL))
        #expect(record.phase == .exited)
    }

    @Test func startFailureIsRecorded() async throws {
        let home = try TemporaryDirectory()
        // Executable bit set but not a valid program.
        let bogus = try home.write("bogus", "not a program", executable: true)
        let coordinator = coordinator(home)
        await #expect(throws: LaunchError.self) {
            try await coordinator.launch(LaunchTarget(id: "b", title: "B", url: bogus), monado: nil)
        }
        guard case .failed = coordinator.latestRecord(for: "b")?.phase else {
            Issue.record("expected a failed record")
            return
        }
    }

    @Test func newMonadoConnectionMarksConnected() async throws {
        let home = try TemporaryDirectory()
        let script = try home.write("app.sh", "#!/bin/sh\nexec sleep 30\n", executable: true)
        let coordinator = coordinator(home)
        let before = try await monadoStatus(in: home, running: true, connections: 1)
        let id = try await coordinator.launch(LaunchTarget(id: "a", title: "A", url: script), monado: before)

        coordinator.observe(before)
        #expect(coordinator.activeRecord(for: "a")?.phase == .running, "the existing connection is not this app's")

        coordinator.observe(try await monadoStatus(in: home, running: true, connections: 2))
        #expect(coordinator.activeRecord(for: "a")?.phase == .connected)
        coordinator.stop(id)
        _ = try await waitUntilEnded(coordinator, id)
    }

    @Test func matchingPresentingClientMarksPresenting() async throws {
        let home = try TemporaryDirectory()
        let script = try home.write("app.sh", "#!/bin/sh\nexec sleep 30\n", executable: true)
        let coordinator = coordinator(home)
        let id = try await coordinator.launch(
            LaunchTarget(id: "brush", title: "Open Brush", url: script, openXRApplicationName: "Open Brush"), monado: nil)
        let status = try await monadoStatus(in: home, running: true, connections: 2, clients: [
            MonadoClientInfo(id: 1, name: "SwiftXR Shell", flags: [.sessionActive]),
            MonadoClientInfo(id: 2, name: "Open Brush", flags: [.sessionActive, .sessionVisible, .primaryApplication]),
        ])
        coordinator.observe(status)
        let record = try #require(coordinator.activeRecord(for: "brush"))
        #expect(record.phase == .presenting)
        #expect(record.clientName == "Open Brush")
        coordinator.stop(id)
        _ = try await waitUntilEnded(coordinator, id)
    }
}

@Suite("Crash reports")
struct CrashReportFinderTests {
    @Test func findsOnlyNewReportsForTheProcess() throws {
        let home = try TemporaryDirectory()
        let old = try home.write("r/App-2026-01-01-000000.ips", "old")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        try home.write("r/Other-2026-11-07-120000.ips", "other")
        let finder = CrashReportFinder(directories: [home.url.appending(path: "r")])
        let since = Date()
        #expect(finder.report(forProcess: "App", since: since) == nil)
        let new = try home.write("r/App-2026-11-07-120001.ips", "new")
        #expect(finder.report(forProcess: "App", since: since)?.lastPathComponent == new.lastPathComponent)
    }
}
