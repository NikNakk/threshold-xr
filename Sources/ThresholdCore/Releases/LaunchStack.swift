import Foundation

/// The shared path contract consumed by threshold-run and the Steam Play adapter.
/// It selects client files only; Monado service activation is a separate action.
public struct LaunchStack: Codable, Sendable {
    public var schema = "threshold-xr/launch-stack-1"
    public var id: String
    public var monadoBuildTag: String
    public var native: Native
    public var artifacts: [String: String]
    public var provenance: [Provenance]
    public var frameworkRunner: String? = nil

    public struct Native: Codable, Sendable {
        public var components: [String: String]
        public var runtimeJSON: String
        enum CodingKeys: String, CodingKey { case components; case runtimeJSON = "runtime_json" }
    }
    public struct Provenance: Codable, Sendable {
        public var component: String
        public var version: String
        public var commit: String
        public var manifestSHA256: String
        enum CodingKeys: String, CodingKey { case component, version, commit; case manifestSHA256 = "manifest_sha256" }
    }
    enum CodingKeys: String, CodingKey {
        case schema, id, native, artifacts, provenance
        case monadoBuildTag = "monado_build_tag"
        case frameworkRunner = "framework_runner"
    }

    public static func selectedURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/Threshold XR/selected-launch-stack.json")
    }

    /// Revalidates every saved release manifest against the stack pin before exposing paths.
    public static func resolve(_ installed: InstalledReleaseStack, root: URL) throws -> LaunchStack {
        try installed.stack.validate()
        let fm = FileManager.default
        var directories: [String: URL] = [:]
        var provenance: [Provenance] = []
        var tag: String?
        for pin in installed.stack.releases {
            // Version is derived from the validated tag, never from an unchecked path.
            let version = String(pin.tag.dropFirst("threshold-".count))
            let directory = root.appending(path: "\(pin.component)/\(version)")
            let bytes = try Data(contentsOf: directory.appending(path: "threshold-release.json"))
            guard ReleaseRepository.digest(bytes) == pin.manifestSHA256 else {
                throw ReleaseError.invalid("Installed release manifest changed for \(pin.component).")
            }
            let release = try JSONDecoder().decode(ComponentRelease.self, from: bytes)
            try release.validate(pin: pin)
            for artifact in release.artifacts {
                directories["\(pin.component)/\(artifact.platform)"] = directory.appending(path: artifact.platform)
            }
            provenance.append(.init(component: pin.component, version: version, commit: release.commit,
                                    manifestSHA256: pin.manifestSHA256))
            if pin.component == "monado" { tag = release.provides["build_tag"] }
        }
        func required(_ component: String, _ relative: String) throws -> URL {
            guard let directory = directories[component] else { throw ReleaseError.invalid("Stack needs \(component).") }
            let path = directory.appending(path: relative)
            guard fm.fileExists(atPath: path.path) else { throw ReleaseError.invalid("Missing installed file: \(path.path)") }
            return path
        }
        let runtime = try required("monado/macos-arm64", "share/openxr/1/openxr_monado.json")
        let xrizer = try required("xrizer/macos-arm64", "libxrizer.dylib")
        guard let tag, let kk = directories["kosmickrisp/macos-arm64"] else {
            throw ReleaseError.invalid("Native launch stacks need Monado, xrizer and KosmicKrisp.")
        }
        let enumerator = fm.enumerator(at: kk, includingPropertiesForKeys: [.isRegularFileKey])
        let icds = (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.pathExtension == "json" && $0.lastPathComponent.lowercased().contains("kosmickrisp") &&
            (FileProbe.readJSONObject($0)?["ICD"] as? [String: Any])?["library_path"] is String
        }
        guard icds.count == 1 else { throw ReleaseError.invalid("Expected one installed KosmicKrisp ICD.") }
        var components = ["xrizer": xrizer.path, "kk_icd": icds[0].path]
        // Native hosts and ANGLE remain explicit external profile components. Prefer
        // packaged loaders when present, otherwise retain the profile's adopted loaders.
        for (name, library) in [("openxr_loader", "libopenxr_loader.dylib"), ("vulkan_loader", "libvulkan.1.dylib")] {
            for key in ["monado/macos-arm64", "kosmickrisp/macos-arm64", "xrizer/macos-arm64"] {
                if let candidate = directories[key]?.appending(path: "lib/\(library)"), fm.fileExists(atPath: candidate.path) {
                    components[name] = candidate.path
                    break
                }
            }
        }
        return LaunchStack(id: installed.id, monadoBuildTag: tag,
                           native: Native(components: components, runtimeJSON: runtime.path),
                           artifacts: directories.mapValues(\.path), provenance: provenance)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
