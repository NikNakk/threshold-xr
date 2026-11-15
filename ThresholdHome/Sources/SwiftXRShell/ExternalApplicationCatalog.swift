import Foundation
import ThresholdCore

/// Home's external applications: ThresholdCore's `ApplicationCatalog`, the
/// same list Threshold XR shows (Home's `apps.json` and the applications
/// threshold-runtime provides).
enum ExternalApplicationCatalog {
    static func context() -> DiscoveryContext { .current() }

    static var catalogURL: URL { ShellAppCatalog.url(context: context()) }

    /// Reads both sources; runs threshold-run, so call it off the main thread.
    static func load() -> (applications: [ShellApplication], problems: [ApplicationCatalog.Problem]) {
        let context = context()
        do {
            if try ShellAppCatalog.createIfMissing(context: context) {
                print("[shell] created external app catalog at \(ShellAppCatalog.url(context: context).path)")
            }
        } catch {
            print("[shell] could not create the external app catalog: \(error.localizedDescription)")
        }
        let catalog = ApplicationCatalog.load(context: context)
        return (catalog.targets.map(ShellApplication.init(target:)), catalog.problems)
    }
}
