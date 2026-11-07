import Foundation
import Testing
@testable import ThresholdCore

/// Trimmed from the real service log of 7 November 2026: the compositor
/// failed to set 90 Hz, then the retry could not claim the USB interface.
let failedRunLog = """
 INFO [ipc_server_main_common] Monado(XRT) by Collabora et al 'v25.1.0-2479-gae2b6d059' starting up...
 INFO [ipc_server_main_common] Server exiting: '0'
 INFO [ipc_server_main_common] Monado(XRT) by Collabora et al 'v25.1.0-2487-g5559edb41' starting up...
DEBUG [pssense_create_internal] PlayStation Sense controller found
\tResult: XRT_SUCCESS
ERROR [apply_refresh] WSI physical mode did not settle at 90.000 Hz
ERROR [init_window] Could not apply WSI startup refresh 90 Hz
ERROR [comp_main_create_system_compositor] Failed to init compositor 0x7cae364000
ERROR [ipc_server_main_common] ipc_server_init_system_if_available_locked failed: XRT_ERROR_VULKAN [x.c:1240]
ERROR [psvr2_usb_open] Failed to claim USB status interface
ERROR [psvr2_open_system_impl] PSVR2 HMD device creation failed
 INFO [ipc_server_main_common] Server exiting: '0'
"""

@Suite("Monado run log")
struct MonadoRunLogTests {
    @Test func reportsOnlyTheLastRunInPriorityOrder() throws {
        let report = try #require(MonadoRunLog.parseLastRun(failedRunLog))
        #expect(report.buildTag == "v25.1.0-2487-g5559edb41")
        #expect(report.ended)
        #expect(report.problems.first?.summary.contains("refresh rate") == true)
        #expect(report.problems.first?.logLine.contains("did not settle at 90.000 Hz") == true)
        #expect(report.problems.contains { $0.summary.contains("USB interfaces") })
        #expect(report.problems.contains { $0.summary.contains("Vulkan") })
    }

    @Test func cleanRunHasNoProblems() throws {
        let clean = """
         INFO [ipc_server_main_common] Monado(XRT) by Collabora et al 'v25.1.0-2487-g5559edb41' starting up...
         WARN [psvr2_sense_tracking_start] EXPERIMENTAL: tracking started
         INFO [delayed_exit_thread] All clients disconnected for 5000 milliseconds, shutting down.
        """
        let report = try #require(MonadoRunLog.parseLastRun(clean))
        #expect(!report.hasProblems)
        #expect(!report.ended)
    }

    @Test func unknownErrorsStillSurface() throws {
        let text = " INFO [x] Monado(XRT) by Collabora et al 'v1.0.0' starting up...\nERROR [foo] something new broke\n"
        #expect(MonadoRunLog.parseLastRun(text)?.problems.first?.logLine == "ERROR [foo] something new broke")
    }

    @Test func noRunInLog() {
        #expect(MonadoRunLog.parseLastRun("nothing here\n") == nil)
    }
}

@Suite("Launch follows Monado activation and failures")
@MainActor
struct LaunchActivationTests {
    @Test func serviceRunCountMarksBriefConnection() async throws {
        let home = try TemporaryDirectory()
        let script = try home.write("app.sh", "#!/bin/sh\nexec sleep 30\n", executable: true)
        let coordinator = LaunchCoordinator(
            launcher: DirectLauncher(environment: ["PATH": "/usr/bin:/bin"]),
            crashFinder: CrashReportFinder(directories: []),
            logDirectory: home.url.appending(path: "logs"),
            stopGracePeriod: .milliseconds(300), crashReportDelay: .milliseconds(10))

        // Idle before launch (runs = 54 in the idle fixture).
        let before = try await monadoStatus(in: home, running: false)
        let id = try await coordinator.launch(LaunchTarget(id: "a", title: "A", url: script), monado: before)

        // Later: idle again, but launchd has run the service once more and
        // its log reports a failure written after the launch.
        var after = before
        after.job?.runs = 55
        try home.write("monado.log", failedRunLog)
        var report = try #require(MonadoRunLog.parseLastRun(failedRunLog))
        report.logModified = Date()
        after.lastRun = report
        coordinator.observe(after)

        let record = try #require(coordinator.activeRecord(for: "a"))
        #expect(record.phase == .connected)
        #expect(record.monadoProblem?.contains("refresh rate") == true)
        coordinator.stop(id)
        _ = try await waitUntilEnded(coordinator, id)
    }

    @Test func problemsFromBeforeTheLaunchAreIgnored() async throws {
        let home = try TemporaryDirectory()
        let script = try home.write("app.sh", "#!/bin/sh\nexec sleep 30\n", executable: true)
        let coordinator = LaunchCoordinator(
            launcher: DirectLauncher(environment: ["PATH": "/usr/bin:/bin"]),
            crashFinder: CrashReportFinder(directories: []),
            logDirectory: home.url.appending(path: "logs"),
            stopGracePeriod: .milliseconds(300), crashReportDelay: .milliseconds(10))
        var status = try await monadoStatus(in: home, running: false)
        var report = try #require(MonadoRunLog.parseLastRun(failedRunLog))
        report.logModified = Date(timeIntervalSinceNow: -600)
        status.lastRun = report
        let id = try await coordinator.launch(LaunchTarget(id: "a", title: "A", url: script), monado: status)
        coordinator.observe(status)
        #expect(coordinator.activeRecord(for: "a")?.monadoProblem == nil)
        #expect(coordinator.activeRecord(for: "a")?.phase == .running)
        coordinator.stop(id)
        _ = try await waitUntilEnded(coordinator, id)
    }
}
