import Foundation

/// Every application Threshold XR and Threshold Home can start, from both
/// sources: Threshold Home's catalog (`apps.json`) and the applications
/// threshold-runtime provides (`threshold-run --list --json`). Both apps load
/// this one list, so an app added to either source appears in both.
public struct ApplicationCatalog: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case shellCatalog
        case framework
    }

    /// A source that could not be read; the other source's apps are still listed.
    public struct Problem: Sendable, Equatable {
        public var source: Source
        public var message: String
    }

    public var targets: [LaunchTarget]
    public var problems: [Problem]

    public init(targets: [LaunchTarget] = [], problems: [Problem] = []) {
        self.targets = targets
        self.problems = problems
    }

    public func problem(_ source: Source) -> String? {
        problems.first { $0.source == source }?.message
    }

    /// Reads both sources. Running threshold-run reads files only; call it off the main thread.
    public static func load(context: DiscoveryContext) -> ApplicationCatalog {
        merge(
            shell: Result { try ShellAppCatalog.load(context: context) },
            framework: Result { try FrameworkCatalog.load(context: context) },
            context: context
        )
    }

    /// Catalog entries first, then framework applications. A catalog entry
    /// keeps its place if an id clashes (framework ids are prefixed, so only
    /// a deliberate `threshold-runtime.<id>` entry can clash).
    static func merge(
        shell: Result<[ShellAppEntry], Error>,
        framework: Result<[FrameworkProfile], Error>,
        context: DiscoveryContext
    ) -> ApplicationCatalog {
        var catalog = ApplicationCatalog()
        switch shell {
        case let .success(entries):
            catalog.targets += entries.map { LaunchTarget(entry: $0, context: context) }
        case let .failure(error):
            catalog.problems.append(Problem(source: .shellCatalog, message: error.localizedDescription))
        }
        switch framework {
        case let .success(profiles):
            let runner = FrameworkCatalog.runner(context: context)
            let taken = Set(catalog.targets.map(\.id))
            catalog.targets += profiles.map { LaunchTarget(profile: $0, runner: runner) }.filter { !taken.contains($0.id) }
        case let .failure(error):
            catalog.problems.append(Problem(source: .framework, message: error.localizedDescription))
        }
        return catalog
    }
}
