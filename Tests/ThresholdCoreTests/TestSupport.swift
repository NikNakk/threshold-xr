import Foundation
@testable import ThresholdCore

/// A scripted `CommandRunning` that records invocations.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    typealias Handler = (_ arguments: [String]) -> CommandResult
    private let lock = NSLock()
    private var handler: Handler
    private(set) var calls: [[String]] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    func setHandler(_ handler: @escaping Handler) { lock.withLock { self.handler = handler } }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let handler = lock.withLock { calls.append(arguments); return self.handler }
        return handler(arguments)
    }

    var recorded: [[String]] { lock.withLock { calls } }
}

/// A temporary directory removed when the value is released.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "threshold-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relative: String, _ contents: String, executable: Bool = false) throws -> URL {
        let file = url.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return file
    }

    func mkdir(_ relative: String) throws -> URL {
        let dir = url.appending(path: relative)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func context(overrides: [String: String] = [:], environment: [String: String] = [:]) -> DiscoveryContext {
        DiscoveryContext(
            homeDirectory: url,
            userID: 501,
            environment: environment,
            pathOverrides: overrides
        )
    }
}

/// Writes a Monado-style service LaunchAgent and prefix into a fake home.
func makeMonadoInstall(in home: TemporaryDirectory, tag: String = "v25.1.0-2479-gae2b6d059", environment: [String: String] = [:]) throws -> URL {
    let prefix = home.url.appending(path: ".local/monado-test")
    // A fake binary: the build tag as a standalone printable string, plus the
    // environment-variable names it "reads", separated by NUL bytes.
    var bytes = Data([0x7f, 0x45, 0x00])
    for string in [tag, "XRT_FLOOR_EYE_HEIGHT_M", "XRT_FLOOR_ALIGN", "IPC_EXIT_WHEN_IDLE"] {
        bytes.append(contentsOf: Array(string.utf8))
        bytes.append(0)
    }
    let service = prefix.appending(path: "bin/monado-service")
    try FileManager.default.createDirectory(at: service.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: service)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: service.path)
    try home.write(".local/monado-test/bin/monado-service-xpc-control", "#!/bin/sh\n", executable: true)
    try home.write(".local/monado-test/lib/libopenxr_monado.dylib", "")
    try home.write(".local/monado-test/lib/libmonado.dylib", "")
    try home.write(".local/monado-test/share/openxr/1/openxr_monado.json", """
    {"file_format_version": "1.0.0", "runtime": {"name": "Monado",
     "library_path": "../../../lib/libopenxr_monado.dylib",
     "MND_libmonado_path": "../../../lib/libmonado.dylib"}}
    """)

    let plist: [String: Any] = [
        "Label": MonadoInstallation.serviceLabel,
        "ProgramArguments": [service.path],
        "MachServices": [MonadoInstallation.machServiceName: true],
        "RunAtLoad": false,
        "ProcessType": "Interactive",
        "EnvironmentVariables": environment,
        "StandardErrorPath": home.url.appending(path: "Library/Logs/Monado/monado-service.err.log").path,
        "CustomUnknownKey": ["nested": 42],
    ]
    let agent = home.url.appending(path: "Library/LaunchAgents/\(MonadoInstallation.serviceLabel).plist")
    try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agent)
    return agent
}

/// `launchctl print` output captured from this project's development Mac
/// (trimmed), with the job running.
let launchctlPrintRunning = """
gui/501/org.freedesktop.monado.service = {
\tactive count = 1
\tpath = /Users/test/Library/LaunchAgents/org.freedesktop.monado.service.plist
\ttype = LaunchAgent
\tstate = running

\tprogram = /Users/test/.local/monado-psvr2/bin/monado-service
\targuments = {
\t\t/Users/test/.local/monado-psvr2/bin/monado-service
\t}

\tinherited environment = {
\t\tXR_RUNTIME_JSON => /Users/test/.local/monado-psvr2/share/openxr/1/openxr_monado.json
\t}

\tdefault environment = {
\t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin
\t}

\tenvironment = {
\t\tXRT_FLOOR_EYE_HEIGHT_M => 1.72
\t\tIPC_EXIT_WHEN_IDLE => 1
\t\tXPC_SERVICE_NAME => org.freedesktop.monado.service
\t}

\tdomain = gui/501 [100021]
\truns = 55
\tpid = 4242
\timmediate reason = ipc (mach)
\tlast exit code = 0

\tendpoints = {
\t\t"org.freedesktop.monado.metal-ipc" = {
\t\t\tport = 0x143d1b
\t\t\tactive = 1
\t\t}
\t}
}
"""

let launchctlPrintIdle = """
gui/501/org.freedesktop.monado.service = {
\tactive count = 0
\tpath = /Users/test/Library/LaunchAgents/org.freedesktop.monado.service.plist
\tstate = not running
\tprogram = /Users/test/.local/monado-psvr2/bin/monado-service
\truns = 54
\tlast exit code = 0
}
"""
