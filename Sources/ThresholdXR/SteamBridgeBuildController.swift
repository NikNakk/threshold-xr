import Foundation
import Observation
import ThresholdCore

@MainActor
@Observable
final class SteamBridgeBuildController {
    var status = SteamBridgeBuildStatus()
    var isRunning = false
    private let builder = SteamBridgeBuilder(root: SteamBridgeBuilder.defaultRoot())
    private var operation: Task<Void, Never>?
    private var polling: Task<Void, Never>?

    func start(_ request: SteamBridgeBuildRequest, checkOnly: Bool) {
        guard !isRunning else { return }
        isRunning = true
        status = SteamBridgeBuildStatus()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                status = await builder.snapshot()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do { try await builder.run(request, checkOnly: checkOnly) }
            catch { /* The builder records the error and keeps the logs. */ }
            polling?.cancel()
            status = await builder.snapshot()
            isRunning = false
        }
    }

    func cancel() {
        Task { await builder.cancel() }
    }
}
