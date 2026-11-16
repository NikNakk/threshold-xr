import Foundation
import XCTest
@testable import ThresholdCore

final class SteamBridgeBuilderTests: XCTestCase {
    private struct BadDownload: ReleaseDownloading {
        func download(_ url: URL, to destination: URL, maximumSize: Int64) async throws {
            try Data("unexpected archive".utf8).write(to: destination)
        }
    }
    private func fixture(_ root: URL, failure: String = "", delay: String = "") throws -> SteamBridgeBuilder {
        let tools = root.appending(path: "tools with spaces")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let script = """
        import json, os, pathlib, sys, time
        args = sys.argv[1:]
        with open(os.environ['FIXTURE_ARGS'], 'a') as f: f.write(json.dumps(args) + '\\n')
        print('running ' + args[0], flush=True)
        if args[0] == os.environ.get('FIXTURE_FAIL'): sys.exit(7)
        if args[0] == os.environ.get('FIXTURE_DELAY'): time.sleep(60)
        if '--output' in args: pathlib.Path(args[args.index('--output') + 1]).mkdir()
        """
        try script.write(to: tools.appending(path: "bridge.py"), atomically: true, encoding: .utf8)
        return SteamBridgeBuilder(root: root.appending(path: "builds"), tools: tools,
            environment: ["FIXTURE_ARGS": root.appending(path: "arguments.jsonl").path,
                          "FIXTURE_FAIL": failure, "FIXTURE_DELAY": delay])
    }

    private func calls(_ root: URL) throws -> [[String]] {
        try String(contentsOf: root.appending(path: "arguments.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }

    func testRequestRejectsUnverifiedArchivesAndNonHTTPSDownloads() throws {
        let runtime = URL(fileURLWithPath: "/runtime")
        XCTAssertThrowsError(try SteamBridgeBuildRequest(sdk: .archive(URL(fileURLWithPath: "/sdk.tar.gz"), sha256: ""), runtime: runtime).validate())
        XCTAssertThrowsError(try SteamBridgeBuildRequest(sdk: .download(URL(string: "http://example.com/sdk")!, sha256: String(repeating: "a", count: 64)), runtime: runtime).validate())
        XCTAssertThrowsError(try SteamBridgeBuildRequest(sdk: .directory(URL(fileURLWithPath: "/sdk")), runtime: runtime, jobs: 0).validate())
    }

    func testCheckOnlyDoesNotCompileStageOrTouchRuntime() async throws {
        let temporary = try TemporaryDirectory()
        let builder = try fixture(temporary.url)
        let runtime = temporary.url.appending(path: "untouched runtime")
        try await builder.run(.init(sdk: .directory(temporary.url.appending(path: "sdk")), runtime: runtime), checkOnly: true)
        let status = await builder.snapshot()
        XCTAssertEqual(status.phase, .ready)
        XCTAssertEqual(try calls(temporary.url).map { $0[0] }, ["doctor", "verify-runtime"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
        let logs = try XCTUnwrap(status.directory).appending(path: "logs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.appending(path: "steam-bridge-doctor").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.appending(path: "steam-bridge-verify-runtime").path))
    }

    func testBuildStagesNewRuntimeAndPreservesArgumentBoundaries() async throws {
        let temporary = try TemporaryDirectory()
        let builder = try fixture(temporary.url)
        let runtime = temporary.url.appending(path: "original runtime")
        let sdk = temporary.url.appending(path: "sdk with spaces")
        try await builder.run(.init(sdk: .directory(sdk), runtime: runtime, jobs: 3))
        let status = await builder.snapshot()
        let commands = try calls(temporary.url)
        XCTAssertEqual(commands.map { $0[0] }, ["doctor", "verify-runtime", "build", "stage-runtime"])
        XCTAssertTrue(commands[2].contains(sdk.path))
        XCTAssertTrue(commands[2].contains(runtime.path))
        XCTAssertEqual(commands[2].suffix(2), ["--jobs", "3"])
        XCTAssertEqual(status.phase, .complete)
        XCTAssertNotEqual(status.runtime, runtime)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(status.runtime).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
    }

    func testFailureRetainsLogsAndDoesNotStage() async throws {
        let temporary = try TemporaryDirectory()
        let builder = try fixture(temporary.url, failure: "build")
        do {
            try await builder.run(.init(sdk: .directory(temporary.url.appending(path: "sdk")), runtime: temporary.url.appending(path: "runtime")))
            XCTFail("Expected compile failure")
        } catch {}
        let status = await builder.snapshot()
        XCTAssertEqual(status.phase, .failed)
        XCTAssertNotNil(status.logURL)
        XCTAssertTrue(status.logTail.contains("running build"))
        XCTAssertFalse(try calls(temporary.url).contains { $0[0] == "stage-runtime" })
    }

    func testCancellationAndConcurrentBuildRejection() async throws {
        let temporary = try TemporaryDirectory()
        let builder = try fixture(temporary.url, delay: "build")
        let request = SteamBridgeBuildRequest(sdk: .directory(temporary.url.appending(path: "sdk")), runtime: temporary.url.appending(path: "runtime"))
        let operation = Task { try await builder.run(request) }
        for _ in 0..<100 {
            let status = await builder.snapshot()
            if status.phase == .building && status.logTail.contains("running build") { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        do { try await builder.run(request); XCTFail("Expected concurrent build rejection") } catch {}
        await builder.cancel()
        do { try await operation.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let status = await builder.snapshot()
        XCTAssertEqual(status.phase, .cancelled)
        XCTAssertFalse(try calls(temporary.url).contains { $0[0] == "stage-runtime" })
    }

    func testBundledBuilderIsAvailable() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: SteamBridgeBuilder.bundledTools.appending(path: "bridge.py").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: SteamBridgeBuilder.bundledTools.appending(path: "inputs.json").path))
    }

    func testRealBundledSetupCheckWhenInputsAreSupplied() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sdk = environment["THRESHOLD_TEST_STEAM_SDK"],
              let runtime = environment["THRESHOLD_TEST_STEAM_RUNTIME"] else {
            throw XCTSkip("Supply a paired development bundle and runtime for the real toolchain check")
        }
        let temporary = try TemporaryDirectory()
        let builder = SteamBridgeBuilder(root: temporary.url.appending(path: "checks"))
        try await builder.run(.init(sdk: .directory(URL(fileURLWithPath: sdk)), runtime: URL(fileURLWithPath: runtime)), checkOnly: true)
        let status = await builder.snapshot()
        XCTAssertEqual(status.phase, .ready)
        XCTAssertTrue(status.logTail.contains("Runtime matches SDK"))
    }

    func testDownloadedChecksumMismatchStopsBeforeExtraction() async throws {
        let temporary = try TemporaryDirectory()
        let builder = SteamBridgeBuilder(root: temporary.url.appending(path: "builds"), downloader: BadDownload())
        let request = SteamBridgeBuildRequest(sdk: .download(URL(string: "https://example.com/sdk.tar.gz")!, sha256: String(repeating: "a", count: 64)),
                                             runtime: temporary.url.appending(path: "runtime"))
        do { try await builder.run(request); XCTFail("Expected checksum rejection") } catch {}
        let status = await builder.snapshot()
        XCTAssertEqual(status.phase, .failed)
        XCTAssertTrue(status.message?.contains("checksum failed") == true)
        XCTAssertNil(status.logURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(status.directory).appending(path: "sdk").path))
    }
}
