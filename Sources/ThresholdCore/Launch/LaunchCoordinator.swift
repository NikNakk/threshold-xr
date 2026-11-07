import Foundation
import Observation

/// One launch and what happened to it.
public struct LaunchRecord: Sendable, Equatable, Identifiable {
    public enum Phase: Sendable, Equatable {
        case starting
        /// The process is running; no Monado connection seen yet.
        case running
        /// A new connection to the installed Monado service appeared after
        /// the launch (or libmonado lists a matching client).
        case connected
        /// Monado reports the app's session as visible or active.
        case presenting
        case stopping
        /// Ended normally, or was stopped by the user.
        case exited
        /// Ended by a crash signal, or macOS wrote a crash report.
        case crashed
        /// Could not start, or ended with a non-zero status.
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .starting, .running, .connected, .presenting, .stopping: return true
            case .exited, .crashed, .failed: return false
            }
        }
    }

    public let id: UUID
    public let targetID: String
    public let title: String
    public let startedAt: Date
    public var phase: Phase
    public var pid: Int32?
    public var logURL: URL?
    public var exit: ProcessExit?
    public var endedAt: Date?
    public var crashReport: URL?
    public var stopRequested = false
    /// The Monado client name matched to this launch, when known.
    public var clientName: String?
    /// Monado connections already open before the launch (nil when the
    /// service was not running, i.e. zero).
    var baselineConnections: Int

    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// Starts targets and follows them until they exit. Never changes Monado's
/// primary or focused client: if Threshold Home is running, its existing
/// hand-over to independently started sessions does that.
@MainActor
@Observable
public final class LaunchCoordinator {
    public private(set) var records: [LaunchRecord] = []

    private let launcher: any ApplicationLaunching
    private let crashFinder: CrashReportFinder
    private let logDirectory: URL
    private let stopGracePeriod: Duration
    private let crashReportDelay: Duration
    private var processes: [UUID: any LaunchedProcess] = [:]
    private var targets: [UUID: LaunchTarget] = [:]

    public var onChange: ((LaunchRecord) -> Void)?

    public init(
        launcher: any ApplicationLaunching,
        crashFinder: CrashReportFinder,
        logDirectory: URL,
        stopGracePeriod: Duration = .seconds(3),
        crashReportDelay: Duration = .seconds(2)
    ) {
        self.launcher = launcher
        self.crashFinder = crashFinder
        self.logDirectory = logDirectory
        self.stopGracePeriod = stopGracePeriod
        self.crashReportDelay = crashReportDelay
    }

    public func activeRecord(for targetID: String) -> LaunchRecord? {
        records.last { $0.targetID == targetID && $0.phase.isActive }
    }

    public func latestRecord(for targetID: String) -> LaunchRecord? {
        records.last { $0.targetID == targetID }
    }

    public func preflight(_ target: LaunchTarget, monado: MonadoStatus?) -> [LaunchIssue] {
        LaunchPreflight.check(target, monado: monado, alreadyRunning: activeRecord(for: target.id) != nil)
    }

    /// Launches a target after preflight. Returns the record's id.
    @discardableResult
    public func launch(_ target: LaunchTarget, monado: MonadoStatus?) async throws -> UUID {
        let issues = preflight(target, monado: monado)
        if let blocking = issues.first(where: { $0.severity == .blocking }) {
            throw LaunchError.blocked(blocking.message)
        }
        // Raw socket counts are compared (not libmonado's client list), so a
        // libmonado snapshot that omits or renames clients cannot skew it.
        let baseline = monado?.isServiceRunning == true ? (monado?.sockets?.connectedCount ?? 0) : 0
        let record = LaunchRecord(
            id: UUID(), targetID: target.id, title: target.title, startedAt: Date(),
            phase: .starting, baselineConnections: baseline
        )
        records.append(record)
        if records.count > 100 { records.removeFirst(records.count - 100) }
        targets[record.id] = target

        let process: any LaunchedProcess
        do {
            process = try await launcher.launch(target, logDirectory: logDirectory)
        } catch {
            update(record.id) {
                $0.phase = .failed(error.localizedDescription)
                $0.endedAt = Date()
            }
            targets[record.id] = nil
            throw error
        }
        processes[record.id] = process
        update(record.id) {
            $0.pid = process.pid
            $0.logURL = process.logURL
            if $0.phase == .starting { $0.phase = .running }
        }

        Task { [weak self] in
            let exit = await process.waitForExit()
            await self?.finish(record.id, exit: exit)
        }
        return record.id
    }

    /// Asks a launch to stop; forces it after the grace period.
    public func stop(_ id: UUID) {
        guard let process = processes[id], record(id)?.phase.isActive == true else { return }
        update(id) {
            $0.stopRequested = true
            $0.phase = .stopping
        }
        process.requestStop()
        Task { [weak self, stopGracePeriod] in
            try? await Task.sleep(for: stopGracePeriod)
            guard let self, self.record(id)?.phase.isActive == true else { return }
            self.processes[id]?.forceStop()
        }
    }

    /// Updates connection state from a fresh Monado status. Attribution is
    /// best effort: a client whose name matches the target is used when
    /// libmonado was queried; otherwise a new connection after launch.
    public func observe(_ status: MonadoStatus) {
        for record in records where [.running, .connected, .presenting].contains(record.phase) {
            guard let target = targets[record.id] else { continue }
            var phase = record.phase
            var clientName = record.clientName

            if let snapshot = status.runtimeQuery.snapshot,
               let client = snapshot.clients.first(where: { client in
                   let name = client.name.lowercased()
                   return !name.isEmpty && target.clientNameCandidates.contains { $0 == name || name.contains($0) || $0.contains(name) }
               }) {
                clientName = client.name
                phase = client.flags.contains(.sessionVisible) || client.flags.contains(.sessionActive) ? .presenting : .connected
            } else if status.isServiceRunning, let count = status.sockets?.connectedCount,
                      count > record.baselineConnections, phase == .running {
                phase = .connected
            }

            if phase != record.phase || clientName != record.clientName {
                update(record.id) {
                    $0.phase = phase
                    $0.clientName = clientName
                }
            }
        }
    }

    // MARK: Private

    private func finish(_ id: UUID, exit: ProcessExit) async {
        processes[id] = nil
        guard let current = record(id) else { return }
        update(id) {
            $0.exit = exit
            $0.endedAt = Date()
            if $0.stopRequested {
                $0.phase = .exited
            } else if exit.isCrash {
                $0.phase = .crashed
            } else if case let .exited(code) = exit, code != 0 {
                $0.phase = .failed("Exited with status \(code).")
            } else {
                $0.phase = .exited
            }
        }

        // macOS writes crash reports shortly after the process dies; this is
        // the only crash signal for apps opened through Launch Services.
        guard !current.stopRequested, let target = targets[id] else {
            targets[id] = nil
            return
        }
        try? await Task.sleep(for: crashReportDelay)
        if let report = crashFinder.report(forProcess: target.processName, since: current.startedAt) {
            update(id) {
                $0.crashReport = report
                $0.phase = .crashed
            }
        }
        targets[id] = nil
    }

    private func record(_ id: UUID) -> LaunchRecord? {
        records.first { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout LaunchRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        onChange?(records[index])
    }
}
