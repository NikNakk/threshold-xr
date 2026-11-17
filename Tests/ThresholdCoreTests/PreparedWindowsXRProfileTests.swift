import Foundation
import XCTest
@testable import ThresholdCore

final class PreparedWindowsXRProfileTests: XCTestCase {
    private func fixture(_ temporary: TemporaryDirectory, native: Bool = false) throws -> [String: Any] {
        let base = temporary.url
        let environment = [
            "MWXR_IN_PROCESS_WINE": base.appending(path: "wine").path,
            "MWXR_IN_PROCESS_BUILD": base.appending(path: "wine/bridge").path,
            "MWXR_XRIZER_ROOT": base.appending(path: "wine/openvr").path,
            "MWXR_NATIVE_RUNTIME_JSON": base.appending(path: "monado/openxr.json").path,
            "MWXR_WINDOWS_OPENXR_LOADER": base.appending(path: "wine/openvr/openxr_loader.dll").path,
            "MWXR_IN_PROCESS_PREFIX": base.appending(path: native ? "private-prefix" : "public-prefix").path,
        ]
        var paths = ["wine/bin/wine", "wine/bin/wineserver", "wine/lib/wine/x86_64-unix/ntdll.so",
            "wine/lib/wine/x86_64-windows/ntdll.dll", "wine/lib/wine/x86_64-unix/winemetal.so",
            "wine/lib/wine/x86_64-windows/d3d11.dll", "wine/lib/wine/x86_64-windows/dxgi.dll",
            "wine/bridge/x86_64-unix/wineopenxr.so", "wine/bridge/x86_64-windows/wineopenxr.dll",
            "wine/openvr/bin/vrclient_x64.dll", "wine/openvr/openxr_loader.dll"]
        var env = environment
        if native {
            env["ALYX_STEAM_STAND_IN"] = base.appending(path: "wine/bin/mwxr-steam.exe").path
            env["MWXR_GAME_PREFIXES"] = base.appending(path: "private-prefixes").path
            paths += ["wine/bin/mwxr-steam.exe", "wine/lib/wine/x86_64-unix/lsteamclient.so",
                "wine/lib/wine/x86_64-windows/lsteamclient.dll", "wine/lib/wine/i386-windows/lsteamclient.dll",
                "wine/lib/wine/i386-windows/ntdll.dll"]
        } else {
            env["MWXR_PUBLIC_BRIDGE_ROOT"] = base.appending(path: "wine/bridge").path
            paths += ["monado/libopenxr_monado.dylib"]
            paths += ["run-in-process-openxr", "run-openvr-game", "run-windows-steam", "install-windows-steam",
                      "windows-steam-env", "openxr-launch-settings"].map { "wine/bridge/scripts/\($0).zsh" }
        }
        var hashes: [String: String] = [:]
        for relative in paths {
            let path = try temporary.write(relative, "fixture")
            hashes[path.path] = ReleaseRepository.digest(try Data(contentsOf: path))
        }
        let manifest = try temporary.write("monado/openxr.json", "{\"runtime\":{\"library_path\":\"libopenxr_monado.dylib\"}}")
        hashes[manifest.path] = ReleaseRepository.digest(try Data(contentsOf: manifest))
        return ["schema": "threshold-xr/launch-stack-1", "id": "fixture", "monado_build_tag": "v25.1.0",
                native ? "steam_play" : "windows_xr": ["environment": env, "file_hashes": hashes,
                    "extra_private_metadata": ["preserve": true]]]
    }

    func testPublicProfileNeedsNoNativeSteamAndPreservesDocument() throws {
        let temporary = try TemporaryDirectory()
        let bytes = try JSONSerialization.data(withJSONObject: fixture(temporary))
        let profile = try PreparedWindowsXRProfile(data: bytes)
        XCTAssertEqual(profile.integration, .windowsSteam)
        let destination = temporary.url.appending(path: "selected.json")
        try profile.write(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.url.appending(path: "public-prefix").path))
    }

    func testLegacyProfileRemainsPrivateNativeSteam() throws {
        let temporary = try TemporaryDirectory()
        let bytes = try JSONSerialization.data(withJSONObject: fixture(temporary, native: true))
        XCTAssertEqual(try PreparedWindowsXRProfile(data: bytes).integration, .nativeSteam)
    }

    func testMixedProfileAndTamperedHelperAreRejected() throws {
        let temporary = try TemporaryDirectory()
        var document = try fixture(temporary)
        document["steam_play"] = [:]
        XCTAssertThrowsError(try PreparedWindowsXRProfile(data: JSONSerialization.data(withJSONObject: document)))
        document.removeValue(forKey: "steam_play")
        try temporary.write("wine/bridge/scripts/run-openvr-game.zsh", "tampered")
        XCTAssertThrowsError(try PreparedWindowsXRProfile(data: JSONSerialization.data(withJSONObject: document)))
    }

    func testPublicReleaseRequiresThePairedArchitectures() throws {
        let repository = "NikNakk/threshold-wine-xr"
        var release = ComponentRelease(schema: "threshold-xr/release-1", component: "threshold-wine-xr", version: "test",
            repository: repository, commit: String(repeating: "a", count: 40), built: "2026-11-17T10:00:00Z",
            workflowRun: "https://github.com/\(repository)/actions/runs/1", provides: ["integration": "windows-steam"],
            artifacts: ["macos-x86_64", "windows-x86_64"].map { platform in
                .init(name: "threshold-wine-xr-test-\(platform).tar.xz", platform: platform,
                      sha256: String(repeating: "b", count: 64), size: 1, role: platform == "macos-x86_64" ? "wine-unix" : "wine-dlls")
            })
        let pin = ReleaseStack.Pin(component: release.component, repository: repository, tag: "threshold-test",
                                   manifestSHA256: String(repeating: "c", count: 64))
        XCTAssertNoThrow(try release.validate(pin: pin))
        release.provides["integration"] = "native-steam"
        XCTAssertThrowsError(try release.validate(pin: pin))
        release.provides["integration"] = "windows-steam"
        release.artifacts.removeLast()
        XCTAssertThrowsError(try release.validate(pin: pin))
    }
}
