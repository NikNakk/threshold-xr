import CoreServices
import Foundation

/// Detects installed XR components. Detection is read-only: nothing is
/// executed, installed or modified.
///
/// Each component's candidates are tried in order: the user's override,
/// environment variables the existing scripts honour, registrations and
/// launch profiles, then conventional and developer-workspace locations.
public struct ComponentDiscovery: Sendable {
    public var context: DiscoveryContext

    public init(context: DiscoveryContext) {
        self.context = context
    }

    public func discoverAll(monado: MonadoInstallation? = nil) -> [ComponentStatus] {
        let monado = monado ?? MonadoInstallation.discover(context: context)
        let profile = AlyxLaunchProfile.load(workspace: alyxRoot)
        let wineRuntimes = wineRuntimeCandidates()
        return [
            monadoStatus(monado),
            openXRLoader(),
            xrizer(profile: profile),
            dxmt(wineRuntimes: wineRuntimes),
            kosmicKrisp(profile: profile),
            wine(runtimes: wineRuntimes),
            wineXR(monado: monado),
            alyxHost(profile: profile),
            questHost(),
            thresholdHome(),
        ]
    }

    // MARK: Monado

    public func monadoStatus(_ install: MonadoInstallation) -> ComponentStatus {
        var artifacts: [DetectedArtifact] = []
        let source = artifactSource(install.prefixSource)
        if let exe = install.serviceExecutable {
            artifacts.append(.init(role: "Service", kind: .executable, url: exe, source: source, version: install.buildTag))
        }
        artifacts.append(.init(role: "LaunchAgent", kind: .configuration, url: install.agentPlistURL, source: .knownLocation,
                               detail: install.agentError))
        if let manifest = install.runtimeManifest {
            artifacts.append(.init(role: "Runtime manifest", kind: .manifest, url: manifest.url, source: source))
            if let library = manifest.libraryURL {
                artifacts.append(.init(role: "Runtime library (arm64)", kind: .library, url: library, source: .registration))
            }
        }
        if let libmonado = install.libmonadoURL {
            artifacts.append(.init(role: "libmonado", kind: .library, url: libmonado, source: .registration))
        }
        for (name, url) in install.tools.sorted(by: { $0.key < $1.key }) {
            artifacts.append(.init(role: name, kind: .executable, url: url, source: source))
        }

        var notes: [ComponentNote] = []
        if install.agent == nil {
            notes.append(.warning("No Monado LaunchAgent is registered. Install one with monado-service-xpc-control install."))
        }
        if install.runtimeManifest == nil, install.isInstalled {
            notes.append(.warning("The prefix has no share/openxr/1/openxr_monado.json runtime manifest."))
        } else if let manifest = install.runtimeManifest, !manifest.libraryExists {
            notes.append(.warning("The runtime manifest points to a missing library."))
        }

        let state: DetectionState = install.isInstalled
            ? (install.runtimeManifest?.libraryExists == true && install.agent != nil ? .detected : .partial)
            : (install.agent != nil ? .partial : .notFound)
        return ComponentStatus(
            id: .monado,
            state: state,
            version: install.buildTag,
            location: install.prefix?.path,
            artifacts: artifacts,
            notes: notes,
            source: GitCheckoutInfo.read(at: context.workspace("monado-2"))
        )
    }

    // MARK: OpenXR loader

    public func openXRLoader() -> ComponentStatus {
        var candidates: [(URL, ArtifactSource)] = []
        if let override = context.override(for: .openXRLoader) { candidates.append((override, .userOverride)) }
        candidates += [
            (context.system("/usr/local/lib/libopenxr_loader.dylib"), .knownLocation),
            (context.system("/opt/homebrew/lib/libopenxr_loader.dylib"), .knownLocation),
            (context.workspace("OpenXR-SDK/build/macos/src/loader/Release/libopenxr_loader.dylib"), .workspace),
        ]
        let found = candidates.filter { FileProbe.exists($0.0) }
        let sdk = context.workspace("OpenXR-SDK")
        let sdkVersion = Self.openXRHeaderVersion(sdk.appending(path: "include/openxr/openxr.h"))
        let artifacts = found.map { DetectedArtifact(role: "Loader library", kind: .library, url: $0.0, source: $0.1) }
        var notes: [ComponentNote] = ["SwiftXR Shell and other native OpenXR apps link this loader from /usr/local/lib."]
        if let sdkVersion { notes.append("The OpenXR-SDK checkout is version \(sdkVersion); the installed loader does not record its own version.") }
        return ComponentStatus(
            id: .openXRLoader,
            state: found.isEmpty ? .notFound : .detected,
            version: sdkVersion.map { "SDK \($0)" },
            location: found.first?.0.path,
            artifacts: artifacts,
            notes: notes,
            source: GitCheckoutInfo.read(at: sdk)
        )
    }

    static func openXRHeaderVersion(_ header: URL) -> String? {
        guard let text = try? String(contentsOf: header, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.contains("#define XR_CURRENT_API_VERSION XR_MAKE_VERSION(") }),
              let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")") else { return nil }
        return line[line.index(after: open)..<close].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ".")
    }

    // MARK: xrizer

    public func xrizer(profile: AlyxLaunchProfile?) -> ComponentStatus {
        var artifacts: [DetectedArtifact] = []
        var nativeCandidates: [(URL, ArtifactSource)] = []
        if let override = context.override(for: .xrizer) { nativeCandidates.append((override, .userOverride)) }
        if let url = profile?.url(for: AlyxLaunchProfile.xrizerLibrary) { nativeCandidates.append((url, .launchProfile)) }
        nativeCandidates += [
            (context.workspace("xrizer/target/release/libxrizer.dylib"), .workspace),
            (context.workspace("xrizer/target/aarch64-apple-darwin/release/libxrizer.dylib"), .workspace),
        ]
        let lastRun = lastXrizerVersion()
        if let native = nativeCandidates.first(where: { FileProbe.exists($0.0) }) {
            artifacts.append(.init(role: "Native macOS runtime (Alyx)", kind: .library, url: native.0, source: native.1,
                                   detail: lastRun.map { "Last loaded version: \($0)" }))
        }

        let windows = context.rig("openvr-runtimes/xrizer")
        let manifest = Self.keyValueManifest(windows.appending(path: "manifest.txt"))
        if FileProbe.exists(windows.appending(path: "openvr_api.dll")) {
            let revision = [manifest["Branch"], manifest["Revision"].flatMap { $0 == "unknown" ? nil : $0 }]
                .compactMap { $0 }.joined(separator: " @ ")
            artifacts.append(.init(role: "Windows OpenVR runtime (Wine)", kind: .library,
                                   url: windows.appending(path: "openvr_api.dll"), source: .knownLocation,
                                   version: revision.isEmpty ? nil : revision,
                                   detail: manifest["OpenXR loader"].map { "Bundled OpenXR loader: \($0)" }))
            let client = windows.appending(path: "bin/vrclient_x64.dll")
            if FileProbe.exists(client) {
                artifacts.append(.init(role: "Windows vrclient", kind: .library, url: client, source: .knownLocation))
            }
        }

        let sourceRoot = context.workspace("xrizer")
        let cargoVersion = Self.cargoVersion(sourceRoot.appending(path: "Cargo.toml"))
        return ComponentStatus(
            id: .xrizer,
            state: artifacts.isEmpty ? .notFound : .detected,
            version: lastRun ?? cargoVersion,
            location: artifacts.first?.path,
            artifacts: artifacts,
            notes: ["xrizer is loaded by applications as an OpenVR runtime; it is not launched on its own."],
            source: GitCheckoutInfo.read(at: sourceRoot)
        )
    }

    private func lastXrizerVersion() -> String? {
        let log = context.home(".local/state/xrizer/xrizer.txt")
        guard let text = FileProbe.tail(log, maxBytes: 256 * 1024) else { return nil }
        let marker = "Initializing XRizer version "
        guard let line = text.split(separator: "\n").last(where: { $0.contains(marker) }),
              let range = line.range(of: marker) else { return nil }
        return line[range.upperBound...].split(separator: " ").first.map(String.init)
    }

    static func cargoVersion(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("version") {
            return line.split(separator: "\"").dropFirst().first.map(String.init)
        }
        return nil
    }

    static func keyValueManifest(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            result[line[..<colon].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    // MARK: Wine

    struct WineRuntime {
        var url: URL
        var source: ArtifactSource
    }

    func wineRuntimeCandidates() -> [WineRuntime] {
        var result: [WineRuntime] = []
        if let override = context.override(for: .wine) { result.append(.init(url: override, source: .userOverride)) }
        for variable in ["MWXR_IN_PROCESS_WINE", "MWXR_WINE_TREE"] {
            if let path = context.environment[variable] { result.append(.init(url: context.expand(path), source: .environment)) }
        }
        let crossover = context.workspace("wine-crossover")
        for name in ["runtime-lsteamclient", "runtime", "runtime-wow64"] {
            result.append(.init(url: crossover.appending(path: name), source: .workspace))
        }
        var seen = Set<String>()
        return result.filter { FileProbe.isExecutableFile($0.url.appending(path: "bin/wine")) && seen.insert($0.url.path).inserted }
    }

    func wine(runtimes: [WineRuntime]) -> ComponentStatus {
        var artifacts: [DetectedArtifact] = []
        var version: String?
        for runtime in runtimes {
            // Wine embeds its version ("wine-11.0") in the Unix-side ntdll.
            let ntdll = runtime.url.appending(path: "lib/wine/x86_64-unix/ntdll.so")
            let tag = FileProbe.firstEmbeddedString(in: ntdll, matching: #"wine-\d+\.\d+(\.\d+)?"#)
            version = version ?? tag
            artifacts.append(.init(role: "Wine runtime \(runtime.url.lastPathComponent)", kind: .directory,
                                   url: runtime.url, source: runtime.source, version: tag))
        }
        let runner = context.rig("run-windows-game.zsh")
        if FileProbe.exists(runner) {
            artifacts.append(.init(role: "Windows game runner", kind: .launcher, url: runner, source: .knownLocation))
        }
        let prefix = context.rig("prefix")
        if FileProbe.isDirectory(prefix) {
            artifacts.append(.init(role: "Default Wine prefix", kind: .directory, url: prefix, source: .knownLocation))
        }
        var notes: [ComponentNote] = []
        if runtimes.count > 1 {
            notes.append("Several Wine runtimes are present; the game runner selects one per launch (runtime-lsteamclient by default).")
        }
        return ComponentStatus(
            id: .wine,
            state: runtimes.isEmpty ? .notFound : .detected,
            version: version,
            location: runtimes.first?.url.path,
            artifacts: artifacts,
            notes: notes
        )
    }

    // MARK: DXMT

    func dxmt(wineRuntimes: [WineRuntime]) -> ComponentStatus {
        var artifacts: [DetectedArtifact] = []
        var override = context.override(for: .dxmt)
        if let url = override, FileProbe.exists(url.appending(path: "bin/wine")) {
            // A Wine runtime was given; check it like the others.
            override = nil
            artifacts += dxmtArtifacts(in: url, source: .userOverride)
        }
        for runtime in wineRuntimes {
            artifacts += dxmtArtifacts(in: runtime.url, source: runtime.source)
        }
        let installs = [override.map { ($0, ArtifactSource.userOverride) }, (context.workspace("dxmt/build/install"), .workspace)]
        for case let (url, source)? in installs where FileProbe.exists(url.appending(path: "x86_64-windows/d3d11.dll")) {
            artifacts.append(.init(role: "DXMT build output", kind: .directory, url: url, source: source))
        }
        let installedCount = artifacts.filter { $0.kind == .library }.count
        let sourceRoot = context.workspace("dxmt")
        return ComponentStatus(
            id: .dxmt,
            state: installedCount > 0 ? .detected : (artifacts.isEmpty ? .notFound : .partial),
            version: Self.mesonProjectVersion(sourceRoot.appending(path: "meson.build")),
            location: artifacts.first?.path,
            artifacts: artifacts,
            notes: [
                "DXMT is installed into Wine runtimes (winemetal.so plus d3d11/dxgi DLLs); it is not a standalone application.",
            ] + (installedCount == 0 && !artifacts.isEmpty ? [.warning("DXMT is built but not installed in any detected Wine runtime.")] : []),
            source: GitCheckoutInfo.read(at: sourceRoot)
        )
    }

    private func dxmtArtifacts(in runtime: URL, source: ArtifactSource) -> [DetectedArtifact] {
        let unix = runtime.appending(path: "lib/wine/x86_64-unix/winemetal.so")
        let d3d11 = runtime.appending(path: "lib/wine/x86_64-windows/d3d11.dll")
        guard FileProbe.exists(unix) else { return [] }
        let hasD3D = FileProbe.exists(d3d11)
        return [DetectedArtifact(
            role: "In Wine \(runtime.lastPathComponent)", kind: .library, url: unix, source: source,
            detail: hasD3D ? "winemetal.so and d3d11.dll present" : "winemetal.so present; d3d11.dll missing"
        )]
    }

    static func mesonProjectVersion(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("project(") }),
              let range = line.range(of: "version") else { return nil }
        return line[range.upperBound...].split(separator: "'").dropFirst().first.map(String.init)
    }

    // MARK: KosmicKrisp

    func kosmicKrisp(profile: AlyxLaunchProfile?) -> ComponentStatus {
        var icds: [(URL, ArtifactSource)] = []
        if let override = context.override(for: .kosmicKrisp) { icds.append((override, .userOverride)) }
        if let profileICD = profile?.url(for: AlyxLaunchProfile.kosmicKrispICD) { icds.append((profileICD, .launchProfile)) }
        let icdDirs = [
            context.home(".local/share/vulkan/icd.d"),
            context.system("/opt/homebrew/etc/vulkan/icd.d"),
            context.system("/opt/homebrew/share/vulkan/icd.d"),
            context.system("/usr/local/etc/vulkan/icd.d"),
            context.system("/usr/local/share/vulkan/icd.d"),
        ]
        for dir in icdDirs {
            for file in FileProbe.directoryContents(dir) where file.lastPathComponent.lowercased().contains("kosmickrisp") {
                icds.append((file, .registration))
            }
        }

        var artifacts: [DetectedArtifact] = []
        var version: String?
        var seen = Set<String>()
        for (url, source) in icds where FileProbe.exists(url) && seen.insert(url.path).inserted {
            if url.pathExtension == "dylib" {
                artifacts.append(.init(role: "Vulkan driver library", kind: .library, url: url, source: source))
                continue
            }
            let json = FileProbe.readJSONObject(url)
            let icd = json?["ICD"] as? [String: Any]
            let api = icd?["api_version"] as? String
            version = version ?? api.map { "Vulkan \($0)" }
            artifacts.append(.init(role: source == .launchProfile ? "ICD used by Alyx play profile" : "Vulkan ICD manifest",
                                   kind: .manifest, url: url, source: source, version: api.map { "Vulkan \($0)" }))
            if let path = icd?["library_path"] as? String {
                let library = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                    : url.deletingLastPathComponent().appending(path: path)
                artifacts.append(.init(role: "Driver library", kind: .library, url: library, source: source,
                                       detail: FileProbe.exists(library) ? nil : "Missing: the ICD points to a library that does not exist."))
            }
        }
        let libraryOK = artifacts.contains { $0.kind == .library && $0.exists }
        let sourceRoot = alyxRoot.appending(path: "workspace/alyx-mesa")
        return ComponentStatus(
            id: .kosmicKrisp,
            state: libraryOK ? .detected : (artifacts.isEmpty ? .notFound : .partial),
            version: version,
            location: artifacts.first?.path,
            artifacts: artifacts,
            notes: ["Selected per application through VK_DRIVER_FILES / VK_ICD_FILENAMES; Alyx and Monado's Vulkan compositor paths use it."],
            source: GitCheckoutInfo.read(at: sourceRoot)
        )
    }

    // MARK: Wine XR

    func wineXR(monado: MonadoInstallation) -> ComponentStatus {
        let root = context.override(for: .wineXR) ?? context.workspace("macos-wine-xr")
        var artifacts: [DetectedArtifact] = []
        let source: ArtifactSource = context.override(for: .wineXR) != nil ? .userOverride : .workspace
        if FileProbe.isDirectory(root) {
            artifacts.append(.init(role: "Bridge source", kind: .sourceCheckout, url: root, source: source))
        }
        let gate = root.appending(path: "build-in-process/gate")
        if FileProbe.isDirectory(gate) {
            artifacts.append(.init(role: "In-process bridge build", kind: .directory, url: gate, source: source))
        }
        let steamPlay = context.home("Library/Application Support/macos-wine-xr/steam-play")
        if FileProbe.isDirectory(steamPlay) {
            artifacts.append(.init(role: "Steam Play tool", kind: .directory, url: steamPlay, source: .knownLocation))
        }
        let steamPlayApp = context.home("Applications/Steam Play.app")
        if FileProbe.exists(steamPlayApp) {
            artifacts.append(.init(role: "Steam Play launcher", kind: .bundle, url: steamPlayApp, source: .knownLocation))
        }

        var notes: [ComponentNote] = []
        // The Windows runner selects an x86_64 Monado client; it must carry
        // the same build tag as the installed service or IPC rejects it.
        let runner = context.rig("run-windows-game.zsh")
        if let manifestPath = Self.exportedValue("MWXR_NATIVE_RUNTIME_JSON", inScript: runner, home: context.homeDirectory) {
            let manifestURL = URL(fileURLWithPath: manifestPath)
            let manifest = OpenXRRuntimeManifest.load(manifestURL)
            let tag = manifest?.libraryURL.flatMap {
                FileProbe.firstEmbeddedString(in: $0, matching: #"^v\d+\.\d+\.\d+(-\d+-g[0-9a-f]+)?(-dirty)?$"#)
            }
            artifacts.append(.init(role: "x86_64 Monado client for Wine", kind: .manifest, url: manifestURL,
                                   source: .launchProfile, version: tag))
            if let tag, let serviceTag = monado.buildTag, tag != serviceTag {
                notes.append(.warning("Wine's x86_64 Monado client is \(tag) but the installed service is \(serviceTag). Monado rejects mismatched clients, so Windows XR applications will fail to connect until both are rebuilt from the same revision."))
            } else if manifest == nil {
                notes.append(.warning("The runner's x86_64 Monado runtime manifest is missing."))
            }
        }

        let hasBridge = artifacts.contains { $0.kind == .directory || $0.kind == .bundle }
        return ComponentStatus(
            id: .wineXR,
            state: hasBridge ? .detected : (artifacts.isEmpty ? .notFound : .partial),
            location: root.path,
            artifacts: artifacts,
            notes: notes,
            source: GitCheckoutInfo.read(at: root)
        )
    }

    /// Reads `export NAME=value` from a shell script, expanding `$HOME`.
    static func exportedValue(_ name: String, inScript url: URL, home: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("export \(name)=") else { continue }
            var value = String(trimmed.dropFirst("export \(name)=".count))
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            // `${NAME:-default}` keeps the default.
            if value.hasPrefix("${"), let sep = value.range(of: ":-"), value.hasSuffix("}") {
                value = String(value[sep.upperBound..<value.index(before: value.endIndex)])
            }
            value = value.replacingOccurrences(of: "${HOME}", with: home.path)
                .replacingOccurrences(of: "$HOME", with: home.path)
            return value.contains("$") ? nil : value
        }
        return nil
    }

    // MARK: Native hosts

    var alyxRoot: URL { context.override(for: .alyxHost) ?? context.workspace("alyx-native") }

    func alyxHost(profile: AlyxLaunchProfile?) -> ComponentStatus {
        let root = alyxRoot
        var artifacts: [DetectedArtifact] = []
        let source: ArtifactSource = context.override(for: .alyxHost) != nil ? .userOverride : .workspace
        for launcher in ["run-alyx", "run-alyx-swiftxr", "run-alyx-profile"] {
            let url = root.appending(path: launcher)
            if FileProbe.isExecutableFile(url) {
                artifacts.append(.init(role: "Launcher \(launcher)", kind: .launcher, url: url, source: source))
            }
        }
        if let host = profile?.url(for: AlyxLaunchProfile.host) {
            artifacts.append(.init(role: "Host used by play profile", kind: .executable, url: host, source: .launchProfile,
                                   detail: FileProbe.exists(host) ? nil : "The play profile names a host binary that does not exist."))
        }
        let hostOK = artifacts.contains { $0.kind == .executable && $0.exists }
        let launcherOK = artifacts.contains { $0.kind == .launcher }
        return ComponentStatus(
            id: .alyxHost,
            state: hostOK && launcherOK ? .detected : (artifacts.isEmpty ? .notFound : .partial),
            location: FileProbe.isDirectory(root) ? root.path : nil,
            artifacts: artifacts,
            notes: launcherOK ? ["Launches start an isolated Monado service and leave the installed LaunchAgent unchanged."] : [],
            source: GitCheckoutInfo.read(at: root)
        )
    }

    /// The guest-app framework checkout (`THRESHOLD_RUNTIME`, as its
    /// launchers use, default `~/Code/threshold-runtime`).
    var thresholdRuntimeRoot: URL {
        context.environment["THRESHOLD_RUNTIME"].map(context.expand) ?? context.workspace("threshold-runtime")
    }

    /// Where the framework's builds go (`THRESHOLD_WORKSPACE`, default the
    /// alyx-native workspace), per threshold-runtime's android/Makefile.
    var thresholdWorkspaceRoot: URL {
        context.environment["THRESHOLD_WORKSPACE"].map(context.expand) ?? alyxRoot
    }

    func questHost() -> ComponentStatus {
        let override = context.override(for: .questHost)
        let root = override ?? thresholdRuntimeRoot.appending(path: "android")
        let source: ArtifactSource = override != nil
            ? .userOverride
            : (context.environment["THRESHOLD_RUNTIME"] != nil ? .environment : .workspace)
        var artifacts: [DetectedArtifact] = []
        if FileProbe.exists(root.appending(path: "Makefile")) {
            artifacts.append(.init(role: "Host source (threshold-runtime)", kind: .sourceCheckout, url: root, source: source))
        }
        let bridge = thresholdWorkspaceRoot.appending(path: "build/quest-mvp/bridge-test")
        if FileProbe.exists(bridge) {
            artifacts.append(.init(role: "Bridge test build", kind: .executable, url: bridge,
                                   source: context.environment["THRESHOLD_WORKSPACE"] != nil ? .environment : .workspace))
        }
        let hasSource = artifacts.contains { $0.kind == .sourceCheckout }
        return ComponentStatus(
            id: .questHost,
            state: hasSource && artifacts.contains { $0.kind == .executable } ? .detected : (artifacts.isEmpty ? .notFound : .partial),
            location: hasSource ? root.path : artifacts.first?.path,
            artifacts: artifacts,
            notes: artifacts.isEmpty ? [] : [
                "Provided by the threshold-runtime guest framework; Threshold XR only detects it.",
                "Experimental: Open Brush's Android build runs offscreen through Klepton; headset use is not yet validated.",
            ],
            source: GitCheckoutInfo.read(at: thresholdRuntimeRoot)
        )
    }

    // MARK: Threshold Home

    public static let shellBundleIdentifier = "com.nickkennedy.swiftxr-shell"

    func thresholdHome() -> ComponentStatus {
        var candidates: [(URL, ArtifactSource)] = []
        if let override = context.override(for: .thresholdHome) { candidates.append((override, .userOverride)) }
        if let urls = LSCopyApplicationURLsForBundleIdentifier(Self.shellBundleIdentifier as CFString, nil)?
            .takeRetainedValue() as? [URL] {
            candidates += urls.map { ($0, .registration) }
        }
        candidates += [
            (context.system("/Applications/SwiftXR Shell.app"), .knownLocation),
            (context.home("Applications/SwiftXR Shell.app"), .knownLocation),
            (context.workspace("SwiftXRShell/.build/release/swiftxr-shell"), .workspace),
        ]
        var artifacts: [DetectedArtifact] = []
        var version: String?
        var seen = Set<String>()
        for (url, source) in candidates where FileProbe.exists(url) && seen.insert(url.standardizedFileURL.path).inserted {
            if url.pathExtension == "app" {
                let info = FileProbe.readPlist(url.appending(path: "Contents/Info.plist"))
                let bundleVersion = info?["CFBundleShortVersionString"] as? String
                version = version ?? bundleVersion
                artifacts.append(.init(role: "Application", kind: .bundle, url: url, source: source, version: bundleVersion))
            } else {
                artifacts.append(.init(role: "Development executable", kind: .executable, url: url, source: source))
            }
        }
        let support = context.home("Library/Application Support/SwiftXRShell")
        for file in ["apps.json", "settings.json"] where FileProbe.exists(support.appending(path: file)) {
            artifacts.append(.init(role: "Configuration", kind: .configuration, url: support.appending(path: file), source: .knownLocation))
        }
        return ComponentStatus(
            id: .thresholdHome,
            state: artifacts.contains { $0.kind == .bundle || $0.kind == .executable } ? .detected : .notFound,
            version: version,
            location: artifacts.first?.path,
            artifacts: artifacts,
            notes: ["Threshold Home is currently provided by SwiftXR Shell. It is optional: Monado and applications run without it."],
            source: GitCheckoutInfo.read(at: context.workspace("SwiftXRShell"))
        )
    }

    private func artifactSource(_ source: MonadoInstallation.PrefixSource?) -> ArtifactSource {
        switch source {
        case .userOverride: return .userOverride
        case .launchAgent: return .launchAgent
        case .searchPath, nil: return .knownLocation
        }
    }
}

extension FileProbe {
    public static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
