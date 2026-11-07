import Darwin
import Foundation
import Testing
@testable import ThresholdCore

@Suite("Monado installation discovery")
struct MonadoInstallationTests {
    @Test func followsLaunchAgentProgramPath() throws {
        let home = try TemporaryDirectory()
        _ = try makeMonadoInstall(in: home, environment: ["IPC_EXIT_WHEN_IDLE": "1"])
        let install = MonadoInstallation.discover(context: home.context())
        #expect(install.isInstalled)
        #expect(install.prefixSource == .launchAgent)
        #expect(install.prefix?.lastPathComponent == "monado-test")
        #expect(install.buildTag == "v25.1.0-2479-gae2b6d059")
        #expect(install.runtimeManifest?.libraryExists == true)
        #expect(install.libmonadoURL?.lastPathComponent == "libmonado.dylib")
        #expect(install.tools["monado-service-xpc-control"] != nil)
        #expect(install.socketURL(context: home.context()).path.hasSuffix("Library/Caches/monado/monado_comp_ipc"))
    }

    @Test func overrideWinsOverLaunchAgent() throws {
        let home = try TemporaryDirectory()
        _ = try makeMonadoInstall(in: home)
        try home.write("other/bin/monado-service", "binary", executable: true)
        let install = MonadoInstallation.discover(context: home.context(overrides: ["monado": home.url.appending(path: "other").path]))
        #expect(install.prefixSource == .userOverride)
        #expect(install.prefix?.lastPathComponent == "other")
    }

    @Test func socketHonoursAgentRuntimeDirectory() throws {
        let home = try TemporaryDirectory()
        _ = try makeMonadoInstall(in: home, environment: ["XDG_RUNTIME_DIR": "/tmp/xr-run"])
        let install = MonadoInstallation.discover(context: home.context())
        #expect(install.socketURL(context: home.context()).path == "/tmp/xr-run/monado_comp_ipc")
    }

    @Test func parsesClientEnvironmentAgent() throws {
        let home = try TemporaryDirectory()
        _ = try makeMonadoInstall(in: home)
        let plist: [String: Any] = [
            "Label": MonadoInstallation.clientEnvironmentLabel,
            "ProgramArguments": ["/bin/sh", "-c", "/bin/launchctl setenv XR_RUNTIME_JSON /x/openxr_monado.json && /bin/launchctl setenv XRT_MACOS_CLIENT_COMPOSITOR 1"],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: home.url.appending(path: "Library/LaunchAgents/\(MonadoInstallation.clientEnvironmentLabel).plist"))
        let install = MonadoInstallation.discover(context: home.context())
        #expect(install.clientSessionVariables == ["XR_RUNTIME_JSON": "/x/openxr_monado.json", "XRT_MACOS_CLIENT_COMPOSITOR": "1"])
    }
}

@Suite("OpenXR registration")
struct OpenXRRegistrationTests {
    @Test func resolvesSymlinkedActiveRuntime() throws {
        let home = try TemporaryDirectory()
        _ = try makeMonadoInstall(in: home)
        let install = MonadoInstallation.discover(context: home.context())
        let system = try home.mkdir("system/openxr/1")
        try FileManager.default.createSymbolicLink(
            at: system.appending(path: "active_runtime.json"),
            withDestinationURL: install.runtimeManifest!.url)
        let registration = OpenXRRegistration.discover(
            context: home.context(), sessionOverride: nil,
            directories: [(home.url.appending(path: "none/openxr/1"), .userConfig), (system, .localShare)])
        #expect(registration.activeRuntime?.source == .localShare)
        #expect(registration.activeRuntime?.symlinkTarget == install.runtimeManifest!.url.path)
        // Relative library paths resolve against the symlink's target.
        #expect(registration.activeRuntime?.manifest?.libraryExists == true)
        #expect(registration.systemSelects(install.runtimeManifest))
        #expect(registration.selects(install.runtimeManifest))
    }

    @Test func sessionOverrideTakesPrecedence() throws {
        let home = try TemporaryDirectory()
        _ = try makeMonadoInstall(in: home)
        let install = MonadoInstallation.discover(context: home.context())
        let other = try home.write("other.json", #"{"runtime": {"name": "Other", "library_path": "/nope.dylib"}}"#)
        let registration = OpenXRRegistration.discover(
            context: home.context(), sessionOverride: other.path, directories: [])
        #expect(registration.effectiveManifest?.name == "Other")
        #expect(!registration.selects(install.runtimeManifest))
        #expect(!registration.systemSelects(install.runtimeManifest))
    }
}

@Suite("Component discovery")
struct ComponentDiscoveryTests {
    @Test func parsesAlyxPlayProfile() {
        let text = """
        CURRENT_PLAY = [
                'kk-tests/run-headset-next', 'gaze',
                '--kk-icd', 'build/kk/icd.json',
                '--gaze-host', 'build/host/alyx_host',
                '--gaze-xrizer-library', 'build/xrizer/libxrizer.dylib',
                '--start-menu', '--timeout', '0']
        MVK_PACING = ['--kk-icd', 'other.json']
        """
        let options = AlyxLaunchProfile.parse(text)
        #expect(options["--kk-icd"] == "build/kk/icd.json")
        #expect(options["--gaze-host"] == "build/host/alyx_host")
        #expect(options["--gaze-xrizer-library"] == "build/xrizer/libxrizer.dylib")
        #expect(options["--timeout"] == "0")
        #expect(options["--start-menu"] == nil)
    }

    @Test func reportsNothingInAnEmptyHome() throws {
        let home = try TemporaryDirectory()
        let results = ComponentDiscovery(context: home.context()).discoverAll()
        #expect(results.count == ComponentID.allCases.count)
        for id in [ComponentID.monado, .xrizer, .dxmt, .kosmicKrisp, .wine, .alyxHost, .questHost] {
            #expect(results.first { $0.id == id }?.state == .notFound, "\(id)")
        }
    }

    @Test func findsProfileSelectedDevelopmentBuilds() throws {
        let home = try TemporaryDirectory()
        try home.write("Code/alyx-native/run-alyx", "#!/bin/sh\n", executable: true)
        try home.write("Code/alyx-native/run-alyx-profile", """
        CURRENT_PLAY = [
            '--kk-icd', 'build/kk/icd.json',
            '--gaze-host', 'build/host/alyx_host',
            '--gaze-xrizer-library', 'build/xrizer/libxrizer.dylib']
        """, executable: true)
        try home.write("Code/alyx-native/build/host/alyx_host", "", executable: true)
        try home.write("Code/alyx-native/build/xrizer/libxrizer.dylib", "")
        try home.write("Code/alyx-native/build/kk/libvulkan_kosmickrisp.dylib", "")
        try home.write("Code/alyx-native/build/kk/icd.json",
                       #"{"ICD": {"api_version": "1.4.363", "library_path": "libvulkan_kosmickrisp.dylib"}, "file_format_version": "1.0.1"}"#)

        let discovery = ComponentDiscovery(context: home.context())
        let results = discovery.discoverAll()
        let kk = try #require(results.first { $0.id == .kosmicKrisp })
        #expect(kk.state == .detected)
        #expect(kk.version == "Vulkan 1.4.363")
        #expect(kk.artifacts.first?.source == .launchProfile)
        let xrizer = try #require(results.first { $0.id == .xrizer })
        #expect(xrizer.state == .detected)
        #expect(xrizer.artifacts.first?.path.hasSuffix("build/xrizer/libxrizer.dylib") == true)
        let alyx = try #require(results.first { $0.id == .alyxHost })
        #expect(alyx.state == .detected)
    }

    @Test func kosmicKrispWithMissingLibraryIsIncomplete() throws {
        let home = try TemporaryDirectory()
        let icd = try home.write("kk.json", #"{"ICD": {"api_version": "1.4", "library_path": "/missing/libvulkan_kosmickrisp.dylib"}}"#)
        let results = ComponentDiscovery(context: home.context(overrides: ["kosmickrisp": icd.path])).discoverAll()
        #expect(results.first { $0.id == .kosmicKrisp }?.state == .partial)
    }

    @Test func detectsDXMTInsideWineRuntime() throws {
        let home = try TemporaryDirectory()
        let runtime = "Code/wine-crossover/runtime"
        try home.write("\(runtime)/bin/wine", "", executable: true)
        var ntdll = Data("\u{0}\u{0}0123456789abcdefwine-11.0\u{0}".utf8)
        ntdll.insert(0x7f, at: 0)
        let ntdllURL = home.url.appending(path: "\(runtime)/lib/wine/x86_64-unix/ntdll.so")
        try FileManager.default.createDirectory(at: ntdllURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ntdll.write(to: ntdllURL)
        try home.write("\(runtime)/lib/wine/x86_64-unix/winemetal.so", "")
        try home.write("\(runtime)/lib/wine/x86_64-windows/d3d11.dll", "")

        let results = ComponentDiscovery(context: home.context()).discoverAll()
        let wine = try #require(results.first { $0.id == .wine })
        #expect(wine.state == .detected)
        #expect(wine.version == "wine-11.0")
        let dxmt = try #require(results.first { $0.id == .dxmt })
        #expect(dxmt.state == .detected)
        #expect(dxmt.artifacts.first?.detail == "winemetal.so and d3d11.dll present")
    }

    @Test func warnsWhenWineMonadoClientDoesNotMatchService() throws {
        let home = try TemporaryDirectory()
        _ = try makeMonadoInstall(in: home, tag: "v25.1.0-2479-gae2b6d059")
        var lib = Data([0])
        lib.append(contentsOf: Array("v25.1.0-2300-g1234567ab".utf8))
        lib.append(0)
        let libURL = home.url.appending(path: "x86/libopenxr_monado.dylib")
        try FileManager.default.createDirectory(at: libURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lib.write(to: libURL)
        try home.write("x86/openxr_monado-dev.json", #"{"runtime": {"library_path": "libopenxr_monado.dylib"}}"#)
        try home.write("Windows/run-windows-game.zsh", "export MWXR_NATIVE_RUNTIME_JSON=$HOME/x86/openxr_monado-dev.json\n")

        let monado = MonadoInstallation.discover(context: home.context())
        let results = ComponentDiscovery(context: home.context()).discoverAll(monado: monado)
        let wineXR = try #require(results.first { $0.id == .wineXR })
        #expect(wineXR.notes.contains { $0.severity == .warning && $0.text.contains("v25.1.0-2300-g1234567ab") })
    }

    @Test func readsExportedShellVariables() throws {
        let home = try TemporaryDirectory()
        let script = try home.write("s.zsh", """
        export A=${A:-$HOME/one}
        export B="$HOME/two"
        export C=$UNKNOWN/x
        """)
        #expect(ComponentDiscovery.exportedValue("A", inScript: script, home: home.url) == home.url.path + "/one")
        #expect(ComponentDiscovery.exportedValue("B", inScript: script, home: home.url) == home.url.path + "/two")
        #expect(ComponentDiscovery.exportedValue("C", inScript: script, home: home.url) == nil)
    }

    @Test func readsGitCheckoutWithoutRunningGit() throws {
        let home = try TemporaryDirectory()
        try home.write("repo/.git/HEAD", "ref: refs/heads/feature/x\n")
        try home.write("repo/.git/packed-refs", "# pack-refs\nabcdef0123456789abcdef0123456789abcdef01 refs/heads/feature/x\n")
        let info = try #require(GitCheckoutInfo.read(at: home.url.appending(path: "repo")))
        #expect(info.branch == "feature/x")
        #expect(info.shortCommit == "abcdef012")
    }

    @Test func classifiesPSVR2USBDevices() {
        let state = PSVR2USB.state(from: [
            USBDeviceInfo(vendorID: 0x054C, productID: 0x0CDE, productName: "PS VR2"),
            USBDeviceInfo(vendorID: 0x054C, productID: 0x0610),
        ])
        #expect(state.headsetPresent)
        #expect(state.otherSonyDevices.map(\.productID) == [0x0610])
    }
}

@Suite("Passive socket inspection")
struct SocketInspectorTests {
    /// Opens a real listening Unix socket in this process and checks that
    /// libproc reports it, then that an accepted connection is counted.
    @Test func reportsListeningAndConnectedSockets() throws {
        let dir = try TemporaryDirectory()
        // sun_path is short; use /tmp directly.
        let path = "/tmp/thxr-\(getpid())-\(UInt32.random(in: 0...99999)).sock"
        defer { unlink(path) }

        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(server >= 0)
        defer { close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, size) }
        }
        #expect(bound == 0)
        #expect(listen(server, 4) == 0)
        _ = dir

        let inspector = LibprocSocketInspector()
        let before = try #require(inspector.sockets(of: getpid()))
        #expect(before.isListening(on: path))
        #expect(!before.isListening(on: "/tmp/not-this-one.sock"))

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, size) }
        }
        #expect(connected == 0)
        let accepted = accept(server, nil, nil)
        defer { close(accepted) }

        let after = try #require(inspector.sockets(of: getpid()))
        // The client end and the accepted end are both in this process.
        #expect(after.connectedCount >= before.connectedCount + 2)
    }
}
