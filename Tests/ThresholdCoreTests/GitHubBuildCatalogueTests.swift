import XCTest
@testable import ThresholdCore

private struct CatalogueDownloader: ReleaseDownloading {
    var responses: [String: Data]
    func download(_ url: URL, to destination: URL, maximumSize: Int64) async throws {
        guard let data = responses[url.absoluteString], data.count <= maximumSize else {
            throw ReleaseError.invalid("Network fixture unavailable")
        }
        try data.write(to: destination)
    }
}

final class GitHubBuildCatalogueTests: XCTestCase {
    private func fixture(version: String = "v1", built: String = "2026-11-17T10:00:00Z") throws -> (ComponentRelease, Data, [String: Any]) {
        let artifact = ComponentRelease.Artifact(name: "klepton-\(version)-macos-arm64.tar.xz", platform: "macos-arm64",
                                               sha256: String(repeating: "a", count: 64), size: 123, role: "runtime")
        let release = ComponentRelease(schema: "threshold-xr/release-1", component: "klepton", version: version,
            repository: "NikNakk/Klepton", commit: String(repeating: "a", count: 40), built: built,
            workflowRun: "https://github.com/NikNakk/Klepton/actions/runs/1", provides: [:], artifacts: [artifact])
        let data = try JSONEncoder().encode(release)
        let metadata: [String: Any] = ["tag_name": "threshold-" + version, "draft": false, "prerelease": true,
            "published_at": built, "assets": [
                ["name": "threshold-release.json", "size": data.count, "state": "uploaded", "digest": "sha256:" + ReleaseRepository.digest(data)],
                ["name": artifact.name, "size": 123, "state": "uploaded", "digest": "sha256:" + artifact.sha256]]]
        return (release, data, metadata)
    }

    private func catalogue(_ listings: [[String: Any]], manifests: [String: Data]) throws -> GitHubBuildCatalogue {
        var responses = manifests
        responses["https://api.github.com/repos/NikNakk/Klepton/releases?per_page=20"] = try JSONSerialization.data(withJSONObject: listings)
        return GitHubBuildCatalogue(downloader: CatalogueDownloader(responses: responses))
    }
    private func url(_ version: String) -> String {
        "https://github.com/NikNakk/Klepton/releases/download/threshold-\(version)/threshold-release.json"
    }

    func testDiscoversPrereleaseAndSkipsDraft() async throws {
        let (_, data, metadata) = try fixture()
        var draft = metadata; draft["draft"] = true; draft["published_at"] = "2026-11-18T10:00:00Z"
        let result = await (try catalogue([draft, metadata], manifests: [url("v1"): data])).check(component: "klepton")
        XCTAssertEqual(result.build?.release.version, "v1")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.build?.pin.manifestSHA256, ReleaseRepository.digest(data))
    }

    func testRejectsMissingArchiveAndChangedDigest() async throws {
        let (_, data, metadata) = try fixture()
        var missing = metadata; missing["assets"] = (metadata["assets"] as! [[String: Any]]).prefix(1).map { $0 }
        var altered = metadata
        var assets = metadata["assets"] as! [[String: Any]]; assets[1]["digest"] = "sha256:" + String(repeating: "0", count: 64)
        altered["assets"] = assets
        for invalid in [missing, altered] {
            let result = await (try catalogue([invalid], manifests: [url("v1"): data])).check(component: "klepton")
            XCTAssertNil(result.build); XCTAssertNotNil(result.error)
        }
    }

    func testFallsBackFromIncompleteNewerReleaseWithWarning() async throws {
        let (_, data, metadata) = try fixture()
        let (_, newerData, newer) = try fixture(version: "v2", built: "2026-11-18T10:00:00Z")
        var missing = newer; missing["assets"] = (newer["assets"] as! [[String: Any]]).prefix(1).map { $0 }
        let result = await (try catalogue([metadata, missing], manifests: [url("v1"): data, url("v2"): newerData])).check(component: "klepton")
        XCTAssertEqual(result.build?.release.version, "v1"); XCTAssertNotNil(result.error)
    }

    func testAvailabilityUsesBuildDateAndManifestIdentity() throws {
        let (release, data, _) = try fixture()
        let pin = ReleaseStack.Pin(component: "klepton", repository: release.repository, tag: "threshold-v1", manifestSHA256: ReleaseRepository.digest(data))
        let build = AvailableComponentBuild(release: release, pin: pin)
        XCTAssertEqual(build.availability(among: []), .install)
        var installed = InstalledComponentRelease(release: release, manifestSHA256: pin.manifestSHA256, directory: URL(filePath: "/tmp/example"))
        XCTAssertEqual(build.availability(among: [installed]), .installed)
        installed.manifestSHA256 = String(repeating: "0", count: 64)
        XCTAssertEqual(build.availability(among: [installed]), .conflict)
        installed.release.version = "another"; installed.release.built = "2026-11-16T10:00:00Z"
        XCTAssertEqual(build.availability(among: [installed]), .update)
        installed.release.built = "2026-11-18T10:00:00Z"
        XCTAssertEqual(build.availability(among: [installed]), .newerInstalled)
    }

    func testNetworkFailureIsNotReportedAsNoUpdates() async throws {
        let result = await GitHubBuildCatalogue(downloader: CatalogueDownloader(responses: [:])).check(component: "klepton")
        XCTAssertNil(result.build); XCTAssertNotNil(result.error)
    }

    func testLivePublishedBuildInstallWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["THRESHOLD_TEST_LIVE_RELEASES"] == "1" else { throw XCTSkip("Optional live GitHub installation") }
        let check = await GitHubBuildCatalogue().check(component: "kosmickrisp")
        let build = try XCTUnwrap(check.build, check.error ?? "No published build")
        let temporary = try TemporaryDirectory()
        let installer = ReleaseInstaller(root: temporary.url)
        try await installer.install(build.pin)
        let installed = await installer.installedComponents()
        XCTAssertEqual(build.availability(among: installed), .installed)
        let stacks = await installer.installedStacks()
        XCTAssertTrue(stacks.isEmpty)
    }
}
