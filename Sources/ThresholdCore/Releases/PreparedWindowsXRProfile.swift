import Foundation

/// Selects an explicitly prepared public/private profile without activating Wine, Steam or Monado.
/// Existing pre-mode `steam_play` records remain private native Steam profiles.
public struct PreparedWindowsXRProfile: Sendable {
    public enum Integration: String, Sendable {
        case windowsSteam = "windows-steam"
        case nativeSteam = "native-steam"
        public var displayName: String {
            self == .windowsSteam ? "Windows Steam" : "Private native macOS Steam"
        }
    }
    public let id: String
    public let integration: Integration
    private let bytes: Data

    public init(data: Data) throws {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              document["schema"] as? String == "threshold-xr/launch-stack-1",
              let id = document["id"] as? String, !id.isEmpty,
              let tag = document["monado_build_tag"] as? String, !tag.isEmpty else {
            throw ReleaseError.invalid("Choose a prepared Threshold XR launch-stack profile.")
        }
        let publicSelection = document["windows_xr"] as? [String: Any]
        let privateSelection = document["steam_play"] as? [String: Any]
        guard (publicSelection != nil) != (privateSelection != nil),
              let selection = publicSelection ?? privateSelection else {
            throw ReleaseError.invalid("Public Windows Steam and private native Steam must use separate profiles.")
        }
        let mode = selection["integration"] as? String ?? (publicSelection == nil ? "native-steam" : "windows-steam")
        guard let integration = Integration(rawValue: mode),
              (integration == .windowsSteam) == (publicSelection != nil),
              let environment = selection["environment"] as? [String: String],
              let hashes = selection["file_hashes"] as? [String: String], !hashes.isEmpty else {
            throw ReleaseError.invalid("The prepared Windows XR integration mode or file inventory is invalid.")
        }
        let common: Set<String> = ["MWXR_IN_PROCESS_WINE", "MWXR_IN_PROCESS_BUILD", "MWXR_XRIZER_ROOT",
            "MWXR_NATIVE_RUNTIME_JSON", "MWXR_WINDOWS_OPENXR_LOADER", "MWXR_IN_PROCESS_PREFIX"]
        let keys = common.union(integration == .windowsSteam ? ["MWXR_PUBLIC_BRIDGE_ROOT"] : ["ALYX_STEAM_STAND_IN", "MWXR_GAME_PREFIXES"])
        guard Set(environment.keys) == keys,
              environment.values.allSatisfy({ $0.hasPrefix("/") }) else {
            throw ReleaseError.invalid("The prepared profile has invalid or missing paths.")
        }
        func path(_ key: String, _ suffix: String = "") -> String {
            suffix.isEmpty ? environment[key]! : URL(fileURLWithPath: environment[key]!).appending(path: suffix).path
        }
        var required = [path("MWXR_IN_PROCESS_WINE", "bin/wine"), path("MWXR_IN_PROCESS_WINE", "bin/wineserver"),
            path("MWXR_IN_PROCESS_WINE", "lib/wine/x86_64-unix/ntdll.so"),
            path("MWXR_IN_PROCESS_WINE", "lib/wine/x86_64-windows/ntdll.dll"),
            path("MWXR_IN_PROCESS_WINE", "lib/wine/x86_64-unix/winemetal.so"),
            path("MWXR_IN_PROCESS_WINE", "lib/wine/x86_64-windows/d3d11.dll"),
            path("MWXR_IN_PROCESS_WINE", "lib/wine/x86_64-windows/dxgi.dll"),
            path("MWXR_IN_PROCESS_BUILD", "x86_64-unix/wineopenxr.so"),
            path("MWXR_IN_PROCESS_BUILD", "x86_64-windows/wineopenxr.dll"),
            path("MWXR_XRIZER_ROOT", "bin/vrclient_x64.dll"), path("MWXR_WINDOWS_OPENXR_LOADER"), path("MWXR_NATIVE_RUNTIME_JSON")]
        if integration == .windowsSteam {
            for name in ["run-in-process-openxr", "run-openvr-game", "run-windows-steam", "install-windows-steam", "windows-steam-env", "openxr-launch-settings"] {
                required.append(path("MWXR_PUBLIC_BRIDGE_ROOT", "scripts/\(name).zsh"))
            }
            let runtime = URL(fileURLWithPath: path("MWXR_NATIVE_RUNTIME_JSON"))
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime)) as? [String: Any],
                  let details = json["runtime"] as? [String: Any], let library = details["library_path"] as? String else {
                throw ReleaseError.invalid("The prepared profile's native OpenXR manifest is invalid.")
            }
            required.append(URL(fileURLWithPath: library, relativeTo: runtime.deletingLastPathComponent()).standardizedFileURL.path)
        } else {
            required += [path("ALYX_STEAM_STAND_IN"), path("MWXR_IN_PROCESS_WINE", "lib/wine/x86_64-unix/lsteamclient.so"),
                path("MWXR_IN_PROCESS_WINE", "lib/wine/x86_64-windows/lsteamclient.dll"),
                path("MWXR_IN_PROCESS_WINE", "lib/wine/i386-windows/lsteamclient.dll"),
                path("MWXR_IN_PROCESS_WINE", "lib/wine/i386-windows/ntdll.dll")]
        }
        guard required.allSatisfy({ hashes[$0] != nil }) else {
            throw ReleaseError.invalid("The prepared profile is missing hashes for required components.")
        }
        for (path, expected) in hashes {
            guard path.hasPrefix("/"), ReleaseRepository.isDigest(expected),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  ReleaseRepository.digest(data) == expected else {
                throw ReleaseError.invalid("Prepared Windows XR file changed: \(URL(fileURLWithPath: path).lastPathComponent)")
            }
        }
        self.id = id; self.integration = integration; self.bytes = data
    }

    public func write(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Preserve the complete profile, including private-only metadata unknown to the UI.
        try bytes.write(to: destination, options: .atomic)
    }
}
