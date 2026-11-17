import Foundation
import Observation
import ThresholdCore

@MainActor @Observable
final class BuildCatalogueController {
    var checks: [String: ComponentBuildCheck] = [:]
    var installed: [InstalledComponentRelease] = []
    var checking = false
    var lastChecked: Date?
    var installing: String?
    var installError: String?
    var installMessage: String?
    private let catalogue = GitHubBuildCatalogue()
    private var automaticTask: Task<Void, Never>?
    let components = ReleaseRepository.repositories.keys.sorted()

    var updateCount: Int {
        checks.values.filter { $0.build?.availability(among: installed) == .update }.count
    }

    func start(installer: ReleaseInstaller) {
        guard automaticTask == nil else { return }
        automaticTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(installer: installer)
                do { try await Task.sleep(for: .seconds(3600)) } catch { return }
            }
        }
    }

    func refresh(installer: ReleaseInstaller) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        installed = await installer.installedComponents()
        let service = catalogue
        await withTaskGroup(of: ComponentBuildCheck.self) { group in
            for component in components {
                group.addTask { await service.check(component: component) }
            }
            for await result in group {
                if result.error != nil, result.build == nil, let previous = checks[result.component]?.build {
                    checks[result.component] = ComponentBuildCheck(component: result.component, build: previous, error: result.error)
                } else { checks[result.component] = result }
            }
        }
        lastChecked = Date()
    }

    func install(_ build: AvailableComponentBuild, installer: ReleaseInstaller) async {
        guard installing == nil, build.availability(among: installed).canInstall else { return }
        installing = build.release.component
        installError = nil
        installMessage = nil
        defer { installing = nil }
        do {
            try await installer.install(build.pin)
            installed = await installer.installedComponents()
            installMessage = "Installed \(build.release.component) \(build.release.version). Files are ready in Installed Releases."
        } catch { installError = error.localizedDescription }
    }
}
