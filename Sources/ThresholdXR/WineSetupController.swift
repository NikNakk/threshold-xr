import Foundation
import Observation
import ThresholdCore

@MainActor
@Observable
final class WineSetupController {
    private(set) var release: WineKitRelease?
    private(set) var installed: InstalledWineKit?
    var sourceFolder: URL?
    private(set) var isImporting = false
    private(set) var message: String?
    private(set) var hasError = false
    private var installer: WineKitInstaller?

    init(root: URL = WineKitInstaller.defaultRoot()) {
        do {
            let release = try WineKitRelease.prototype()
            self.release = release
            installer = WineKitInstaller(root: root, release: release)
        } catch { message = error.localizedDescription; hasError = true }
    }

    func refresh() async {
        guard let installer, !isImporting else { return }
        do {
            installed = try await installer.installed()
            if installed != nil { hasError = false }
        } catch { installed = nil; message = error.localizedDescription; hasError = true }
    }

    func prepare() async {
        guard let installer, let sourceFolder, !isImporting else { return }
        isImporting = true
        hasError = false
        message = "Verifying the downloaded package and extracting Wine…"
        defer { isImporting = false }
        do {
            installed = try await installer.install(from: sourceFolder)
            message = "Packaged Wine is ready. Its matching development bundle is saved for the optional Steam bridge build."
        } catch { installed = nil; message = error.localizedDescription; hasError = true }
    }
}
