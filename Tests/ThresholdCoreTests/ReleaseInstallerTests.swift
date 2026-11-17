import XCTest
@testable import ThresholdCore

private struct FixtureDownloader: ReleaseDownloading {
    var assets: [String: Data]
    func download(_ url: URL, to destination: URL, maximumSize: Int64) async throws {
        guard let bytes = assets[url.lastPathComponent], bytes.count <= maximumSize else {
            throw ReleaseError.invalid("Missing or oversized fixture")
        }
        try bytes.write(to: destination)
    }
}

final class ReleaseInstallerTests: XCTestCase {
    // Minimal POSIX tar fixtures let us exercise libarchive without an external tool.
    private func tar(name: String, contents: String = "payload", type: UInt8 = 48, link: String = "") -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, _ start: Int, _ length: Int) {
            for (i, byte) in text.utf8.prefix(length).enumerated() { header[start + i] = byte }
        }
        put(name, 0, 100)
        put("0000755", 100, 8)
        put("0000000", 108, 8)
        put("0000000", 116, 8)
        let payload = type == 48 ? Data(contents.utf8) : Data()
        put(String(format: "%011o", payload.count), 124, 12)
        put("00000000000", 136, 12)
        put("        ", 148, 8)
        header[156] = type
        put(link, 157, 100)
        put("ustar", 257, 6)
        put("00", 263, 2)
        put(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", 148, 8)
        var bytes = Data(header)
        bytes.append(payload)
        bytes.append(Data(repeating: 0, count: (512 - payload.count % 512) % 512 + 1024))
        return bytes
    }

    private func fixture(archive: Data) throws -> (ReleaseStack, FixtureDownloader) {
        let artifact = ComponentRelease.Artifact(name: "xrizer-test-macos-arm64.tar.xz", platform: "macos-arm64",
                                                sha256: ReleaseRepository.digest(archive), size: Int64(archive.count), role: "runtime")
        var windows = artifact
        windows.name = "xrizer-test-windows-x86_64.tar.xz"
        windows.platform = "windows-x86_64"
        let release = ComponentRelease(schema: "threshold-xr/release-1", component: "xrizer", version: "test",
                                       repository: "NikNakk/xrizer", commit: String(repeating: "a", count: 40),
                                       built: "2026-11-16T10:00:00Z", workflowRun: "https://github.com/NikNakk/xrizer/actions/runs/1",
                                       provides: [:], artifacts: [artifact, windows])
        let manifest = try JSONEncoder().encode(release)
        let pin = ReleaseStack.Pin(component: "xrizer", repository: "NikNakk/xrizer", tag: "threshold-test",
                                   manifestSHA256: ReleaseRepository.digest(manifest))
        return (ReleaseStack(schema: "threshold-xr/stack-1", id: "test", channel: "experimental", releases: [pin]),
                FixtureDownloader(assets: ["threshold-release.json": manifest, artifact.name: archive, windows.name: archive]))
    }

    func testVerifiedInstallAndReceipt() async throws {
        let temporary = try TemporaryDirectory()
        let (stack, downloader) = try fixture(archive: tar(name: "xrizer/libxrizer.dylib"))
        let installer = ReleaseInstaller(root: temporary.url, downloader: downloader)
        try await installer.install(stack)
        let library = temporary.url.appending(path: "xrizer/test/macos-arm64/libxrizer.dylib")
        XCTAssertEqual(try String(contentsOf: library, encoding: .utf8), "payload")
        let installed = await installer.installedStacks()
        XCTAssertEqual(installed.map(\.id), ["test"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.url.appending(path: "current").path))
    }

    func testSingleBuildInventoryAndNoStackReceipt() async throws {
        let temporary = try TemporaryDirectory()
        let (stack, downloader) = try fixture(archive: tar(name: "xrizer/libxrizer.dylib"))
        let installer = ReleaseInstaller(root: temporary.url, downloader: downloader)
        try await installer.install(stack.releases[0])
        let installed = await installer.installedComponents()
        XCTAssertEqual(installed.map { $0.release.component }, ["xrizer"])
        XCTAssertEqual(installed.first?.manifestSHA256, stack.releases[0].manifestSHA256)
        let stacks = await installer.installedStacks()
        XCTAssertTrue(stacks.isEmpty)
        try await installer.install(stack.releases[0]) // Byte-identical retries are safe.
        try FileManager.default.removeItem(at: temporary.url.appending(path: "xrizer/test/windows-x86_64"))
        let damaged = await installer.installedComponents()
        XCTAssertTrue(damaged.isEmpty)
    }

    func testManifestTamperingDoesNotInstall() async throws {
        let temporary = try TemporaryDirectory()
        var (stack, downloader) = try fixture(archive: tar(name: "xrizer/libxrizer.dylib"))
        stack.releases[0].manifestSHA256 = String(repeating: "0", count: 64)
        let installer = ReleaseInstaller(root: temporary.url, downloader: downloader)
        do { try await installer.install(stack); XCTFail("Accepted a changed manifest") } catch {}
        let installed = await installer.installedStacks()
        XCTAssertTrue(installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.url.appending(path: "xrizer").path))
    }

    func testArchiveTamperingDoesNotInstall() async throws {
        let temporary = try TemporaryDirectory()
        var (stack, downloader) = try fixture(archive: tar(name: "xrizer/libxrizer.dylib"))
        downloader.assets["xrizer-test-macos-arm64.tar.xz"] = tar(name: "xrizer/libxrizer.dylib", contents: "changed")
        let installer = ReleaseInstaller(root: temporary.url, downloader: downloader)
        do { try await installer.install(stack); XCTFail("Accepted a changed archive") } catch {}
        let installed = await installer.installedStacks()
        XCTAssertTrue(installed.isEmpty)
    }

    func testUnsafeArchivesNeverEscapeStaging() throws {
        let temporary = try TemporaryDirectory()
        let destination = try temporary.mkdir("extract")
        for bytes in [tar(name: "root/../../escaped"), tar(name: "/absolute"),
                      tar(name: "root/link", type: 50, link: "../../escaped"),
                      tar(name: "root/link", type: 50, link: "/tmp/escaped"),
                      tar(name: "root/link", type: 49, link: "root/file"),
                      tar(name: "root/device", type: 51)] {
            let archive = temporary.url.appending(path: "test.tar.xz")
            try bytes.write(to: archive)
            XCTAssertThrowsError(try ReleaseInstaller.extract(archive, to: destination))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.url.appending(path: "escaped").path))
    }

    func testSafeRelativeSymlink() throws {
        let temporary = try TemporaryDirectory()
        let destination = try temporary.mkdir("extract")
        let archive = temporary.url.appending(path: "test.tar.xz")
        try tar(name: "root/lib/link", type: 50, link: "../file").write(to: archive)
        try ReleaseInstaller.extract(archive, to: destination)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appending(path: "lib/link").path), "../file")
    }

    func testRealXZArchiveInstalls() async throws {
        let temporary = try TemporaryDirectory()
        try temporary.write("payload/xrizer/libxrizer.dylib", "xz fixture")
        let archive = temporary.url.appending(path: "fixture.tar.xz")
        let result = try await ProcessCommandRunner().run("/usr/bin/tar", arguments: [
            "-cJf", archive.path, "-C", temporary.url.appending(path: "payload").path, "xrizer",
        ], timeout: 10)
        XCTAssertTrue(result.succeeded, result.combinedOutput)
        let (stack, downloader) = try fixture(archive: Data(contentsOf: archive))
        let root = try temporary.mkdir("components")
        try await ReleaseInstaller(root: root, downloader: downloader).install(stack)
        XCTAssertEqual(try String(contentsOf: root.appending(path: "xrizer/test/macos-arm64/libxrizer.dylib"), encoding: .utf8), "xz fixture")
    }

    func testStackRejectsTraversalUnknownForkAndDuplicatePins() throws {
        var (stack, _) = try fixture(archive: tar(name: "root/file"))
        stack.id = "../escape"
        XCTAssertThrowsError(try stack.validate())
        stack.id = "test"
        stack.releases[0].repository = "someone/xrizer"
        XCTAssertThrowsError(try stack.validate())
        stack.releases[0].repository = "NikNakk/xrizer"
        stack.releases.append(stack.releases[0])
        XCTAssertThrowsError(try stack.validate())
    }

    func testMonadoRequiresBothArchitectures() throws {
        let pin = ReleaseStack.Pin(component: "monado", repository: "NikNakk/monado", tag: "threshold-test",
                                   manifestSHA256: String(repeating: "a", count: 64))
        let release = ComponentRelease(schema: "threshold-xr/release-1", component: "monado", version: "test",
                                       repository: pin.repository, commit: String(repeating: "a", count: 40),
                                       built: "2026-11-16T10:00:00Z", workflowRun: "https://github.com/NikNakk/monado/actions/runs/1",
                                       provides: ["build_tag": "vtest"], artifacts: [
                                        .init(name: "monado-test-macos-arm64.tar.xz", platform: "macos-arm64",
                                              sha256: String(repeating: "a", count: 64), size: 100, role: "service"),
                                       ])
        XCTAssertThrowsError(try release.validate(pin: pin))
    }
}
