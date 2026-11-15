import Foundation

/// Every application Threshold XR and Threshold Home can start, from three
/// sources: Threshold Home's catalog (`apps.json`), the applications
/// threshold-runtime provides (`threshold-run --list --json`), and the VR
/// games macOS Steam has installed. Both apps load this one list, so an app
/// added to any source appears in both.
public struct ApplicationCatalog: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case shellCatalog
        case framework
        case steam
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
            steam: Result { try SteamLibrary.installedVRGames(context: context) },
            context: context
        )
    }

    /// Catalog entries first, then framework applications, then Steam games. An
    /// earlier source keeps its place if an id clashes (framework and Steam ids
    /// are prefixed, so only a deliberate `threshold-runtime.<id>` or
    /// `steam.<appid>` entry can clash).
    static func merge(
        shell: Result<[ShellAppEntry], Error>,
        framework: Result<[FrameworkProfile], Error>,
        steam: Result<[SteamGame], Error> = .success([]),
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
        switch steam {
        case let .success(games):
            let taken = Set(catalog.targets.map(\.id))
            catalog.targets += games.map(LaunchTarget.init(steamGame:)).filter { !taken.contains($0.id) }
        case let .failure(error):
            catalog.problems.append(Problem(source: .steam, message: "macOS Steam's library could not be read: \(error.localizedDescription)"))
        }
        return catalog
    }
}
