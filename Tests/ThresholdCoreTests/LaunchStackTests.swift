import Foundation
import XCTest
@testable import ThresholdCore

final class LaunchStackTests: XCTestCase {
    private func installed(_ temporary: TemporaryDirectory) throws -> InstalledReleaseStack {
        var pins: [ReleaseStack.Pin] = []
        for component in ["monado", "xrizer", "kosmickrisp"] {
            let platforms = component == "monado" ? ["macos-arm64", "macos-x86_64"] :
                (component == "xrizer" ? ["macos-arm64", "windows-x86_64"] : ["macos-arm64"])
            let artifacts = platforms.map { platform in
                ComponentRelease.Artifact(name: "\(component)-test-\(platform).tar.xz", platform: platform,
                                          sha256: String(repeating: "a", count: 64), size: 100,
                                          role: component == "monado" ? (platform == "macos-arm64" ? "service" : "wine-client") : "runtime")
            }
            let release = ComponentRelease(schema: "threshold-xr/release-1", component: component, version: "test",
                                           repository: ReleaseRepository.repositories[component]!, commit: String(repeating: "a", count: 40),
                                           built: "2026-11-16T10:00:00Z", workflowRun: "https://github.com/\(ReleaseRepository.repositories[component]!)/actions/runs/1",
                                           provides: component == "monado" ? ["build_tag": "v25.1.0-1-gabcdef1"] : [:], artifacts: artifacts)
            let bytes = try JSONEncoder().encode(release)
            try temporary.write("\(component)/test/threshold-release.json", String(decoding: bytes, as: UTF8.self))
            pins.append(.init(component: component, repository: release.repository, tag: "threshold-test",
                              manifestSHA256: ReleaseRepository.digest(bytes)))
        }
        try temporary.write("monado/test/macos-arm64/share/openxr/1/openxr_monado.json", "{\"runtime\":{\"library_path\":\"../../../lib/libopenxr_monado.dylib\"}}")
        try temporary.write("monado/test/macos-arm64/lib/libopenxr_monado.dylib", "v25.1.0-1-gabcdef1")
        try temporary.write("xrizer/test/macos-arm64/libxrizer.dylib", "fixture")
        try temporary.write("kosmickrisp/test/macos-arm64/share/vulkan/icd.d/kosmickrisp_icd.aarch64.json", "{\"ICD\":{\"library_path\":\"../../../lib/libvulkan_kosmickrisp.dylib\"}}")
        try temporary.write("kosmickrisp/test/macos-arm64/lib/libvulkan_kosmickrisp.dylib", "fixture")
        return InstalledReleaseStack(stack: .init(schema: "threshold-xr/stack-1", id: "fixture", channel: "experimental", releases: pins),
                                     directory: temporary.url.appending(path: "Stacks/fixture"))
    }

    func testExportsManagedPathsAndPinnedProvenance() throws {
        let temporary = try TemporaryDirectory()
        let selection = try LaunchStack.resolve(installed(temporary), root: temporary.url)
        XCTAssertEqual(selection.monadoBuildTag, "v25.1.0-1-gabcdef1")
        XCTAssertEqual(selection.provenance.count, 3)
        XCTAssertTrue(selection.native.components["xrizer"]!.hasSuffix("xrizer/test/macos-arm64/libxrizer.dylib"))
        XCTAssertNil(selection.native.components["host"])
        XCTAssertNil(selection.native.components["angle"])
        let output = temporary.url.appending(path: "selected.json")
        try selection.write(to: output)
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [String: Any]
        XCTAssertEqual(value["schema"] as? String, "threshold-xr/launch-stack-1")
        XCTAssertEqual(value["monado_build_tag"] as? String, selection.monadoBuildTag)
        XCTAssertEqual((value["native"] as? [String: Any])?["runtime_json"] as? String, selection.native.runtimeJSON)
    }

    func testChangedManifestIsRejectedBeforeExport() throws {
        let temporary = try TemporaryDirectory()
        let stack = try installed(temporary)
        try temporary.write("xrizer/test/threshold-release.json", "{}")
        XCTAssertThrowsError(try LaunchStack.resolve(stack, root: temporary.url))
    }

    func testMissingManagedFileDoesNotFallBackToDeveloperWorkspace() throws {
        let temporary = try TemporaryDirectory()
        let stack = try installed(temporary)
        try FileManager.default.removeItem(at: temporary.url.appending(path: "xrizer/test/macos-arm64/libxrizer.dylib"))
        XCTAssertThrowsError(try LaunchStack.resolve(stack, root: temporary.url))
    }
}
