import Foundation
import Testing
@testable import ThresholdCore

@Suite("launchd status parsing")
struct LaunchdParsingTests {
    @Test func parsesRunningJob() {
        let status = LaunchdJobStatus.parse(launchctlPrint: launchctlPrintRunning)
        #expect(status.state == .running(pid: 4242))
        #expect(status.runs == 55)
        #expect(status.lastExitCode == "0")
        #expect(status.program == "/Users/test/.local/monado-psvr2/bin/monado-service")
        #expect(status.plistPath?.hasSuffix("org.freedesktop.monado.service.plist") == true)
        #expect(status.machServices == ["org.freedesktop.monado.metal-ipc"])
        // Only the job's own environment, not inherited/default.
        #expect(status.environment["XRT_FLOOR_EYE_HEIGHT_M"] == "1.72")
        #expect(status.environment["XR_RUNTIME_JSON"] == nil)
        #expect(status.environment["PATH"] == nil)
        #expect(!status.lastExitWasAbnormal)
    }

    @Test func parsesIdleJob() {
        let status = LaunchdJobStatus.parse(launchctlPrint: launchctlPrintIdle)
        #expect(status.state == .loadedIdle)
        #expect(status.pid == nil)
        #expect(status.isLoaded)
    }

    @Test func treatsMissingStateWithoutPidAsIdle() {
        let tearingDown = launchctlPrintIdle.replacingOccurrences(of: "\tstate = not running\n", with: "")
        #expect(LaunchdJobStatus.parse(launchctlPrint: tearingDown).state == .loadedIdle)
    }

    @Test func detectsAbnormalExit() {
        let crashed = launchctlPrintIdle.replacingOccurrences(of: "last exit code = 0", with: "last exit code = 1\n\tlast terminating signal = Segmentation fault: 11")
        #expect(LaunchdJobStatus.parse(launchctlPrint: crashed).lastExitWasAbnormal)
        let terminated = launchctlPrintIdle.replacingOccurrences(of: "last exit code = 0", with: "last terminating signal = Terminated: 15")
        #expect(!LaunchdJobStatus.parse(launchctlPrint: terminated).lastExitWasAbnormal)
    }
}

@Suite("launchd service control")
struct LaunchdServiceTests {
    func service(_ runner: FakeRunner) -> LaunchdService {
        LaunchdService(label: MonadoInstallation.serviceLabel, domain: "gui/501", runner: runner)
    }

    @Test func reportsNotLoaded() async throws {
        let runner = FakeRunner { _ in CommandResult(exitCode: 113, standardError: "Could not find service") }
        #expect(try await service(runner).status() == .notLoaded)
    }

    @Test func startUsesKickstartWithoutKill() async throws {
        let runner = FakeRunner { _ in CommandResult(exitCode: 0) }
        try await service(runner).start()
        #expect(runner.recorded == [["kickstart", "gui/501/org.freedesktop.monado.service"]])
    }

    @Test func restartUsesKickstartKill() async throws {
        let runner = FakeRunner { _ in CommandResult(exitCode: 0) }
        try await service(runner).restart()
        #expect(runner.recorded == [["kickstart", "-k", "gui/501/org.freedesktop.monado.service"]])
    }

    @Test func stopSendsSigtermAndWaitsForExit() async throws {
        var prints = 0
        let runner = FakeRunner { arguments in
            if arguments.first == "print" {
                prints += 1
                return CommandResult(exitCode: 0, standardOutput: prints < 3 ? launchctlPrintRunning : launchctlPrintIdle)
            }
            return CommandResult(exitCode: 0)
        }
        try await service(runner).stop(timeout: 5, pollInterval: 0.01)
        #expect(runner.recorded.first == ["kill", "SIGTERM", "gui/501/org.freedesktop.monado.service"])
        #expect(prints == 3)
    }

    @Test func stopTimesOutIfProcessStaysRunning() async {
        let runner = FakeRunner { arguments in
            CommandResult(exitCode: 0, standardOutput: arguments.first == "print" ? launchctlPrintRunning : "")
        }
        await #expect(throws: LaunchdServiceError.stopTimedOut(label: MonadoInstallation.serviceLabel, seconds: 0)) {
            try await service(runner).stop(timeout: 0.05, pollInterval: 0.01)
        }
    }

    @Test func actionOnUnloadedJobExplainsIt() async {
        let runner = FakeRunner { _ in CommandResult(exitCode: 113, standardError: "Could not find service \"x\" in domain") }
        await #expect(throws: LaunchdServiceError.notLoaded(label: MonadoInstallation.serviceLabel)) {
            try await service(runner).start()
        }
    }

    @Test func loadRetriesTransientIOError() async throws {
        let home = try TemporaryDirectory()
        let plist = try home.write("agent.plist", "<plist/>")
        var attempts = 0
        let runner = FakeRunner { _ in
            attempts += 1
            return CommandResult(exitCode: attempts < 3 ? 5 : 0, standardError: attempts < 3 ? "Bootstrap failed: 5: Input/output error" : "")
        }
        try await service(runner).load(plist: plist, attempts: 5)
        #expect(attempts == 3)
        #expect(runner.recorded.allSatisfy { $0 == ["bootstrap", "gui/501", plist.path] })
    }

    @Test func loadRequiresPlist() async {
        let runner = FakeRunner { _ in CommandResult(exitCode: 0) }
        await #expect(throws: LaunchdServiceError.self) {
            try await service(runner).load(plist: URL(fileURLWithPath: "/nonexistent/agent.plist"))
        }
        #expect(runner.recorded.isEmpty)
    }

    @Test func reloadUnloadsThenLoads() async throws {
        let home = try TemporaryDirectory()
        let plist = try home.write("agent.plist", "<plist/>")
        let runner = FakeRunner { _ in CommandResult(exitCode: 0) }
        try await service(runner).reload(plist: plist)
        #expect(runner.recorded.map(\.first) == ["bootout", "bootstrap"])
    }
}

@Suite("Runtime query safety policy")
struct RuntimeQueryPolicyTests {
    let socket = "/tmp/monado_comp_ipc"
    let running = LaunchdJobStatus(state: .running(pid: 10))
    let idleExit = ["IPC_EXIT_WHEN_IDLE": "1"]

    @Test func neverConnectsWhenServiceIsStopped() {
        let decision = RuntimeQueryPolicy().decide(
            job: LaunchdJobStatus(state: .loadedIdle), sockets: nil, socketPath: socket,
            agentEnvironment: [:], explicitRequest: true)
        #expect(decision != .query, "connecting would start the service via XPC")
    }

    @Test func neverConnectsBeforeListening() {
        let decision = RuntimeQueryPolicy().decide(
            job: running, sockets: ProcessSocketSummary(listeningPaths: [], connectedCount: 0), socketPath: socket,
            agentEnvironment: [:], explicitRequest: true)
        #expect(decision != .query)
    }

    @Test func skipsAutomaticQueryWithNoClientsAndIdleExit() {
        let decision = RuntimeQueryPolicy().decide(
            job: running, sockets: ProcessSocketSummary(listeningPaths: [socket], connectedCount: 0), socketPath: socket,
            agentEnvironment: idleExit, explicitRequest: false)
        #expect(decision != .query, "disconnecting would start the idle-exit timer")
    }

    @Test func queriesWhenAnotherClientIsConnected() {
        let decision = RuntimeQueryPolicy().decide(
            job: running, sockets: ProcessSocketSummary(listeningPaths: [socket], connectedCount: 1), socketPath: socket,
            agentEnvironment: idleExit, explicitRequest: false)
        #expect(decision == .query)
    }

    @Test func queriesIdleServiceWhenIdleExitIsOff() {
        let decision = RuntimeQueryPolicy().decide(
            job: running, sockets: ProcessSocketSummary(listeningPaths: [socket], connectedCount: 0), socketPath: socket,
            agentEnvironment: [:], explicitRequest: false)
        #expect(decision == .query)
    }

    @Test func respectsDisabledAutomaticQueries() {
        let decision = RuntimeQueryPolicy(automaticQueriesEnabled: false).decide(
            job: running, sockets: ProcessSocketSummary(listeningPaths: [socket], connectedCount: 2), socketPath: socket,
            agentEnvironment: idleExit, explicitRequest: false)
        #expect(decision != .query)
    }

    @Test func explicitRequestOverridesClientCount() {
        let decision = RuntimeQueryPolicy().decide(
            job: running, sockets: ProcessSocketSummary(listeningPaths: [socket], connectedCount: 0), socketPath: socket,
            agentEnvironment: idleExit, explicitRequest: true)
        #expect(decision == .query)
    }
}

/// Fakes for the controller's passive probes.
struct FakeSockets: ProcessSocketInspecting {
    var summary: ProcessSocketSummary?
    func sockets(of pid: Int32) -> ProcessSocketSummary? { summary }
}

struct FakeUSB: USBDeviceEnumerating {
    var list: [USBDeviceInfo]
    func devices(vendorID: Int) -> [USBDeviceInfo] { list.filter { $0.vendorID == vendorID } }
}

final class CountingQuerier: RuntimeQuerying, @unchecked Sendable {
    var count = 0
    func snapshot(libmonado: URL) throws -> MonadoRuntimeSnapshot {
        count += 1
        return MonadoRuntimeSnapshot(
            apiVersion: "1.8.0",
            clients: [MonadoClientInfo(id: 1, name: "hello_xr", flags: [.primaryApplication, .sessionFocused])],
            devices: [MonadoDeviceInfo(id: 0, index: 0, name: "PS VR2", serial: nil, isHead: true)],
            takenAt: Date()
        )
    }
}

@Suite("Monado status aggregation")
struct MonadoControllerTests {
    @Test func keepsStatesDistinctWhenIdleWithHeadsetPlugged() async throws {
        let home = try TemporaryDirectory()
        _ = try makeMonadoInstall(in: home, environment: ["IPC_EXIT_WHEN_IDLE": "1"])
        let runner = FakeRunner { arguments in
            arguments.first == "print" ? CommandResult(exitCode: 0, standardOutput: launchctlPrintIdle) : CommandResult(exitCode: 1)
        }
        let querier = CountingQuerier()
        let controller = MonadoController(
            context: home.context(), runner: runner, sockets: FakeSockets(summary: nil),
            usb: FakeUSB(list: [USBDeviceInfo(vendorID: 0x054C, productID: 0x0CDE)]), querier: querier)
        let status = await controller.refresh(explicitQuery: true)
        #expect(status.installState == .installed)
        #expect(status.serviceState == .idle)
        #expect(status.runtimeState == .stopped)
        #expect(status.headsetState == .connected)
        #expect(querier.count == 0, "an idle service must never be connected to")
    }

    @Test func runningListeningWithClientIsReadyAndQueried() async throws {
        let home = try TemporaryDirectory()
        _ = try makeMonadoInstall(in: home, environment: ["IPC_EXIT_WHEN_IDLE": "1"])
        let socket = home.url.appending(path: "Library/Caches/monado/monado_comp_ipc").path
        let runner = FakeRunner { arguments in
            arguments.first == "print" ? CommandResult(exitCode: 0, standardOutput: launchctlPrintRunning) : CommandResult(exitCode: 1)
        }
        let querier = CountingQuerier()
        let controller = MonadoController(
            context: home.context(), runner: runner,
            sockets: FakeSockets(summary: ProcessSocketSummary(listeningPaths: [socket], connectedCount: 1)),
            usb: FakeUSB(list: []), querier: querier)
        let status = await controller.refresh()
        #expect(status.serviceState == .running(pid: 4242))
        #expect(status.runtimeState == .ready)
        #expect(status.headsetState == .activeInRuntime("PS VR2"))
        #expect(status.connectedClientEstimate == 1)
        #expect(querier.count == 1)
        // Rate-limited: a second automatic refresh reuses the snapshot.
        _ = await controller.refresh()
        #expect(querier.count == 1)
    }

    @Test func runningWithoutListenerIsStarting() async throws {
        let home = try TemporaryDirectory()
        _ = try makeMonadoInstall(in: home)
        let runner = FakeRunner { _ in CommandResult(exitCode: 0, standardOutput: launchctlPrintRunning) }
        let controller = MonadoController(
            context: home.context(), runner: runner,
            sockets: FakeSockets(summary: ProcessSocketSummary(listeningPaths: [], connectedCount: 0)),
            usb: FakeUSB(list: []), querier: CountingQuerier())
        let status = await controller.refresh()
        #expect(status.runtimeState == .starting)
        #expect(status.headsetState == .notDetected)
    }

    @Test func reportsMissingInstallation() async throws {
        let home = try TemporaryDirectory()
        let runner = FakeRunner { _ in CommandResult(exitCode: 113, standardError: "Could not find service") }
        let controller = MonadoController(context: home.context(), runner: runner,
                                          sockets: FakeSockets(summary: nil), usb: FakeUSB(list: []), querier: CountingQuerier())
        let status = await controller.refresh()
        #expect(status.installState == .notInstalled)
        #expect(status.serviceState == .notRegistered)
    }

    @Test func detectsSettingsWaitingForReload() async throws {
        let home = try TemporaryDirectory()
        // Plist says 1.80; the loaded job (fixture) has 1.72.
        _ = try makeMonadoInstall(in: home, environment: ["XRT_FLOOR_EYE_HEIGHT_M": "1.80", "IPC_EXIT_WHEN_IDLE": "1"])
        let runner = FakeRunner { _ in CommandResult(exitCode: 0, standardOutput: launchctlPrintRunning) }
        let controller = MonadoController(context: home.context(), runner: runner,
                                          sockets: FakeSockets(summary: nil), usb: FakeUSB(list: []), querier: CountingQuerier())
        let status = await controller.refresh()
        #expect(status.pendingEnvironmentChanges == ["XRT_FLOOR_EYE_HEIGHT_M"])
    }
}
