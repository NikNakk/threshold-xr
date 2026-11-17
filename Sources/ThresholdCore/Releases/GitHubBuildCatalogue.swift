import Foundation

public struct AvailableComponentBuild: Sendable {
    public var release: ComponentRelease
    public var pin: ReleaseStack.Pin
    public var page: URL {
        URL(string: "https://github.com/\(pin.repository)/releases/tag/\(pin.tag)")!
    }

    public enum Availability: String, Sendable {
        case install = "Install", update = "Update", installed = "Installed"
        case newerInstalled = "Newer build installed", conflict = "Release changed"
        public var canInstall: Bool { self == .install || self == .update }
    }

    public func availability(among installed: [InstalledComponentRelease]) -> Availability {
        let matches = installed.filter { $0.release.component == release.component }
        if let same = matches.first(where: { $0.release.version == release.version }) {
            return same.manifestSHA256 == pin.manifestSHA256 ? .installed : .conflict
        }
        guard !matches.isEmpty else { return .install }
        let date = ISO8601DateFormatter().date(from: release.built) ?? .distantPast
        if matches.contains(where: { (ISO8601DateFormatter().date(from: $0.release.built) ?? .distantPast) >= date }) {
            return .newerInstalled
        }
        return .update
    }
}

public struct ComponentBuildCheck: Sendable {
    public var component: String
    public var build: AvailableComponentBuild?
    public var error: String?
    public init(component: String, build: AvailableComponentBuild?, error: String?) {
        self.component = component; self.build = build; self.error = error
    }
}

/// Public release assets only: failed jobs and login-only Actions artifacts are never offered.
public struct GitHubBuildCatalogue: Sendable {
    private let downloader: any ReleaseDownloading
    public init(downloader: any ReleaseDownloading = GitHubReleaseDownloader(timeoutInterval: 30)) { self.downloader = downloader }

    public func check(component: String) async -> ComponentBuildCheck {
        do {
            guard let repository = ReleaseRepository.repositories[component] else {
                throw ReleaseError.invalid("Unsupported component.")
            }
            let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!
            let data = try await bytes(url, limit: 4 * 1024 * 1024)
            let releases = try JSONDecoder().decode([GitHubPublishedRelease].self, from: data)
            // ISO 8601 timestamps from GitHub sort chronologically. Include experimental prereleases.
            let candidates = releases.filter { !$0.draft && $0.tagName.hasPrefix("threshold-") &&
                ReleaseRepository.token($0.tagName) && $0.assets.contains(where: { $0.name == "threshold-release.json" })
            }.sorted { ($0.publishedAt ?? "") > ($1.publishedAt ?? "") }
            var failures: [String] = []
            for candidate in candidates.prefix(3) {
                do {
                    let manifest = try await bytes(ReleaseRepository.assetURL(repository: repository,
                        tag: candidate.tagName, name: "threshold-release.json"), limit: 1024 * 1024)
                    let digest = ReleaseRepository.digest(manifest)
                    let pin = ReleaseStack.Pin(component: component, repository: repository,
                                               tag: candidate.tagName, manifestSHA256: digest)
                    let release = try JSONDecoder().decode(ComponentRelease.self, from: manifest)
                    try release.validate(pin: pin)
                    let expected = [("threshold-release.json", Int64(manifest.count), digest)] +
                        release.artifacts.map { ($0.name, $0.size, $0.sha256) }
                    for (name, size, hash) in expected {
                        let assets = candidate.assets.filter { $0.name == name }
                        guard assets.count == 1, let asset = assets.first, asset.size == size,
                              asset.state == "uploaded", asset.digest == nil || asset.digest == "sha256:" + hash else {
                            throw ReleaseError.invalid("Release \(candidate.tagName) has missing or inconsistent assets.")
                        }
                    }
                    return ComponentBuildCheck(component: component,
                        build: AvailableComponentBuild(release: release, pin: pin),
                        error: failures.isEmpty ? nil : "A newer release is incomplete: " + failures.joined(separator: "; "))
                } catch { failures.append(error.localizedDescription) }
            }
            return ComponentBuildCheck(component: component, build: nil,
                                       error: failures.isEmpty ? nil : failures.joined(separator: "; "))
        } catch {
            return ComponentBuildCheck(component: component, build: nil, error: error.localizedDescription)
        }
    }

    private func bytes(_ url: URL, limit: Int64) async throws -> Data {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "threshold-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await downloader.download(url, to: temporary, maximumSize: limit)
        return try Data(contentsOf: temporary)
    }
}

struct GitHubPublishedRelease: Decodable {
    var tagName: String
    var draft: Bool
    var publishedAt: String?
    var assets: [Asset]
    struct Asset: Decodable {
        var name: String
        var size: Int64
        var state: String
        var digest: String?
    }
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", publishedAt = "published_at", draft, assets
    }
}
