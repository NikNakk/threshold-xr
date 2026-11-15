import Foundation

/// Where Monado is installed and how it is registered with launchd.
///
/// The LaunchAgent is the primary source: its program path identifies the
/// installed prefix the user actually runs. Conventional prefixes are only
/// fallbacks for a missing or unloaded agent.
public struct MonadoInstallation: Sendable, Equatable {
    public static let serviceLabel = "org.freedesktop.monado.service"
    public static let clientEnvironmentLabel = "org.freedesktop.monado.client-environment"
    public static let machServiceName = "org.freedesktop.monado.metal-ipc"
    public static let socketFilename = "monado_comp_ipc"

    public enum PrefixSource: String, Sendable {
        case userOverride = "Your override"
        case launchAgent = "LaunchAgent program path"
        case searchPath = "Standard location"
    }

    public var agentPlistURL: URL
    public var agent: LaunchAgentDefinition?
    public var agentError: String?
    public var clientEnvironmentAgent: LaunchAgentDefinition?

    public var prefix: URL?
    public var prefixSource: PrefixSource?
    public var serviceExecutable: URL?
    public var runtimeManifest: OpenXRRuntimeManifest?
    public var libmonadoURL: URL?
    public var tools: [String: URL]
    /// Build tag embedded in `monado-service`, e.g. `v25.1.0-2479-gae2b6d059`.
    public var buildTag: String?
    public var serviceModified: Date?

    public var isInstalled: Bool { serviceExecutable.map(FileProbe.isExecutableFile) ?? false }

    public var serviceLogURLs: [URL] {
        [agent?.standardErrorPath, agent?.standardOutPath].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
    }

    /// Where the service listens, using the same rules as Monado's
    /// `u_file_get_runtime_dir` on macOS and the agent's own environment.
    public func socketURL(context: DiscoveryContext) -> URL {
        let env = agent?.environment ?? [:]
        if let dir = env["XDG_RUNTIME_DIR"] ?? context.environment["XDG_RUNTIME_DIR"] {
            return URL(fileURLWithPath: dir).appending(path: Self.socketFilename)
        }
        if let cache = env["XDG_CACHE_HOME"] {
            return URL(fileURLWithPath: cache).appending(path: "monado/\(Self.socketFilename)")
        }
        return context.home("Library/Caches/monado/\(Self.socketFilename)")
    }

    /// Variables the client-environment agent places in the login session
    /// (`launchctl setenv NAME VALUE`), parsed from its shell command.
    public var clientSessionVariables: [String: String] {
        guard let arguments = clientEnvironmentAgent?.programArguments else { return [:] }
        let script = arguments.joined(separator: " ")
        var result: [String: String] = [:]
        let pattern = #"launchctl\s+setenv\s+(\S+)\s+(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        for match in regex.matches(in: script, range: NSRange(script.startIndex..., in: script)) {
            guard let key = Range(match.range(at: 1), in: script),
                  let value = Range(match.range(at: 2), in: script) else { continue }
            result[String(script[key])] = String(script[value])
        }
        return result
    }

    public static func discover(context: DiscoveryContext) -> MonadoInstallation {
        let agentURL = context.home("Library/LaunchAgents/\(serviceLabel).plist")
        var agent: LaunchAgentDefinition?
        var agentError: String?
        if FileProbe.exists(agentURL) {
            do { agent = try LaunchAgentDefinition.load(from: agentURL) } catch {
                agentError = error.localizedDescription
            }
        }
        let clientAgent = try? LaunchAgentDefinition.load(
            from: context.home("Library/LaunchAgents/\(clientEnvironmentLabel).plist")
        )

        var prefix: URL?
        var source: PrefixSource?
        var executable: URL?

        if let override = context.override(for: .monado) {
            // Accept either the prefix or the service executable.
            let candidate = FileProbe.isDirectory(override) ? override.appending(path: "bin/monado-service") : override
            if FileProbe.isExecutableFile(candidate) {
                executable = candidate
                source = .userOverride
            }
        }
        if executable == nil, let program = agent?.program {
            let url = URL(fileURLWithPath: program)
            if FileProbe.exists(url) {
                executable = url
                source = .launchAgent
            }
        }
        if executable == nil {
            let fallbacks = [
                context.home(".local/monado/bin/monado-service"),
                context.system("/usr/local/bin/monado-service"),
                context.system("/opt/homebrew/bin/monado-service"),
            ]
            if let found = fallbacks.first(where: FileProbe.isExecutableFile) {
                executable = found
                source = .searchPath
            }
        }
        if let executable {
            prefix = executable.deletingLastPathComponent().deletingLastPathComponent()
        }

        var manifest: OpenXRRuntimeManifest?
        var tools: [String: URL] = [:]
        var libmonado: URL?
        if let prefix {
            manifest = OpenXRRuntimeManifest.load(prefix.appending(path: "share/openxr/1/openxr_monado.json"))
            for tool in ["monado-ctl", "monado-cli", "monado-gui", "monado-service-xpc-control"] {
                let url = prefix.appending(path: "bin/\(tool)")
                if FileProbe.isExecutableFile(url) { tools[tool] = url }
            }
            libmonado = manifest?.libmonadoURL.flatMap { FileProbe.exists($0) ? $0 : nil }
                ?? FileProbe.firstExisting([prefix.appending(path: "lib/libmonado.dylib")])
        }

        let tag = executable.flatMap {
            FileProbe.firstEmbeddedString(in: $0, matching: #"^v\d+\.\d+\.\d+(-\d+-g[0-9a-f]+)?(-dirty)?$"#)
        }

        return MonadoInstallation(
            agentPlistURL: agentURL,
            agent: agent,
            agentError: agentError,
            clientEnvironmentAgent: clientAgent,
            prefix: prefix,
            prefixSource: source,
            serviceExecutable: executable,
            runtimeManifest: manifest,
            libmonadoURL: libmonado,
            tools: tools,
            buildTag: tag,
            serviceModified: executable.flatMap(FileProbe.modificationDate)
        )
    }
}
