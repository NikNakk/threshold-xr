import Foundation
import XCTest
@testable import ThresholdCore

final class WineKitInstallerTests: XCTestCase {
    private func fixture(_ root: URL) throws -> (WineKitRelease, URL) {
        let folder = root.appending(path: "downloads")
        let source = root.appending(path: "source/wine")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [String: String] = [:]
        for name in ["lib/wine/i386-windows/ntdll.dll", "lib/wine/x86_64-windows/ntdll.dll", "lib/wine/x86_64-unix/ntdll.so"] {
            let path = source.appending(path: name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data(name.utf8)
            try bytes.write(to: path)
            files[name] = ReleaseRepository.digest(bytes)
        }
        for name in ["bin/wine", "bin/wineserver"] {
            let path = source.appending(path: name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let archive = folder.appending(path: "wine-fixture.tar.xz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cJf", archive.path, "-C", source.deletingLastPathComponent().path, "wine"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let sdk = folder.appending(path: "sdk.tar.gz")
        // Deliberately not an executable SDK: preparing packaged Wine only copies it.
        try Data("source archive retained without running a compiler".utf8).write(to: sdk)
        func identity(_ path: URL) throws -> WineKitRelease.Archive {
            .init(name: path.lastPathComponent, sha256: try ReleaseInstaller.fileDigest(path),
                  size: Int64(try Data(contentsOf: path).count))
        }
        return (try .init(schema: "threshold-xr/wine-kit-1", id: "fixture", title: "Fixture",
                          downloadURL: URL(string: "https://github.com/NikNakk/threshold-xr/actions/runs/1")!,
                          runtime: identity(archive), sdk: identity(sdk), runtimeFiles: files), folder)
    }

    func testBundledPrototypeHasVerifiedArchiveIdentities() throws {
        let release = try WineKitRelease.prototype()
        XCTAssertEqual(release.id, "prototype-1")
        XCTAssertEqual(release.runtimeFiles.count, 3)
        XCTAssertEqual(release.sdk.sha256, "1a038c3e593f6a32369a1fb084102d0f60ea25c136458a5880ba92abfddd71f5")
    }

    func testPreparesPackagedWineAndRetainsSDKWithoutExecutingIt() async throws {
        let temporary = try TemporaryDirectory()
        let (release, folder) = try fixture(temporary.url)
        let installer = WineKitInstaller(root: temporary.url.appending(path: "packages"), release: release)
        let result = try await installer.install(from: folder)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: result.runtime.appending(path: "bin/wine").path))
        XCTAssertEqual(try ReleaseInstaller.fileDigest(result.sdkArchive), release.sdk.sha256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.runtime.appending(path: "lib/wine/x86_64-unix/lsteamclient.so").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: release.runtime.name).path))
    }

    func testChangedSDKIsRejectedBeforeExtraction() async throws {
        let temporary = try TemporaryDirectory()
        let (release, folder) = try fixture(temporary.url)
        try Data("changed".utf8).write(to: folder.appending(path: release.sdk.name))
        let root = temporary.url.appending(path: "packages")
        let installer = WineKitInstaller(root: root, release: release)
        do { _ = try await installer.install(from: folder); XCTFail("Expected checksum failure") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRuntimeIdentityMismatchCleansStagingAndDoesNotPublish() async throws {
        let temporary = try TemporaryDirectory()
        var (release, folder) = try fixture(temporary.url)
        release.runtimeFiles["lib/wine/x86_64-unix/ntdll.so"] = String(repeating: "a", count: 64)
        let root = temporary.url.appending(path: "packages")
        let installer = WineKitInstaller(root: root, release: release)
        do { _ = try await installer.install(from: folder); XCTFail("Expected identity failure") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: release.id).path))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains(where: { $0.hasPrefix(".import-") }))
    }

    func testRepeatedImportReusesExistingRuntimeWithoutReplacingFiles() async throws {
        let temporary = try TemporaryDirectory()
        let (release, folder) = try fixture(temporary.url)
        let installer = WineKitInstaller(root: temporary.url.appending(path: "packages"), release: release)
        let first = try await installer.install(from: folder)
        let marker = first.runtime.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: marker)
        let second = try await installer.install(from: folder)
        XCTAssertEqual(first.directory, second.directory)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
    }

    func testChangedInstalledRuntimeIsRejectedWithoutOverwritingIt() async throws {
        let temporary = try TemporaryDirectory()
        let (release, folder) = try fixture(temporary.url)
        let installer = WineKitInstaller(root: temporary.url.appending(path: "packages"), release: release)
        let first = try await installer.install(from: folder)
        let path = first.runtime.appending(path: "lib/wine/x86_64-unix/ntdll.so")
        try Data("changed".utf8).write(to: path)
        do { _ = try await installer.install(from: folder); XCTFail("Expected identity failure") } catch {}
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "changed")
    }

    func testRealPrototypeImportWhenDownloadsAreSupplied() async throws {
        guard let path = ProcessInfo.processInfo.environment["THRESHOLD_TEST_WINE_KIT"] else {
            throw XCTSkip("Supply the downloaded CI artifact folder for a real import test")
        }
        let temporary = try TemporaryDirectory()
        let installer = WineKitInstaller(root: temporary.url.appending(path: "packages"), release: try .prototype())
        let result = try await installer.install(from: URL(fileURLWithPath: path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: result.runtime.appending(path: "bin/wine").path))
        let installed = try await installer.installed()
        XCTAssertNotNil(installed)
        let builder = SteamBridgeBuilder(root: temporary.url.appending(path: "bridge-check"))
        try await builder.run(.init(sdk: .archive(result.sdkArchive, sha256: result.release.sdk.sha256),
                                    runtime: result.runtime), checkOnly: true)
        let status = await builder.snapshot()
        XCTAssertEqual(status.phase, .ready)
    }
}
