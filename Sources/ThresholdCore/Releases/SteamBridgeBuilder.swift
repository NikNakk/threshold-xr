import Foundation

public struct SteamBridgeBuildRequest: Sendable {
    public enum SDK: Sendable {
        case directory(URL)
        case archive(URL, sha256: String)
        case download(URL, sha256: String)
    }
    public var sdk: SDK
    public var runtime: URL
    public var jobs: Int

    public init(sdk: SDK, runtime: URL, jobs: Int = 6) {
        self.sdk = sdk
        self.runtime = runtime
        self.jobs = jobs
    }

    public func validate() throws {
        guard runtime.isFileURL, runtime.path.hasPrefix("/"), (1...64).contains(jobs) else {
            throw ReleaseError.invalid("Choose a local Wine runtime and between 1 and 64 build jobs.")
        }
        switch sdk {
        case let .directory(url):
            guard url.isFileURL else { throw ReleaseError.invalid("Choose a local SDK folder.") }
        case let .archive(url, hash):
            guard url.isFileURL, Self.validHash(hash) else {
                throw ReleaseError.invalid("Choose an SDK archive and enter its SHA-256 checksum.")
            }
        case let .download(url, hash):
            guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                  Self.validHash(hash) else {
                throw ReleaseError.invalid("Enter an HTTPS SDK archive URL and its trusted SHA-256 checksum.")
            }
        }
    }

    private static func validHash(_ hash: String) -> Bool {
        hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

public struct SteamBridgeBuildStatus: Sendable {
    public enum Phase: String, Sendable {
        case idle = "Ready to check setup"
        case preparing = "Preparing build"
        case downloading = "Downloading development bundle"
        case unpacking = "Verifying development bundle"
        case checking = "Checking build tools and runtime"
        case ready = "Setup checked"
        case building = "Compiling Steam bridge"
        case staging = "Creating separate runtime"
        case complete = "Local runtime ready"
        case cancelling = "Cancelling build"
        case cancelled = "Build cancelled"
        case failed = "Build failed"
    }
    public var phase: Phase = .idle
    public var directory: URL?
    public var logURL: URL?
    public var runtime: URL?
    public var message: String?
    public var logTail = ""
    public init() {}
}

/// Serialises local builds, logs each child process and stages outputs beside the
/// selected runtime. It never selects a runtime, edits a prefix or launches Steam.
public actor SteamBridgeBuilder {
    private let root: URL
    private let tools: URL
    private let environment: [String: String]
    private let downloader: any ReleaseDownloading
    private var current: ExecutableProcess?
    private var download: Task<Void, Error>?
    private var busy = false
    private var cancelled = false
    private var status = SteamBridgeBuildStatus()

    public init(root: URL, tools: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                downloader: any ReleaseDownloading = GitHubReleaseDownloader()) {
        self.root = root
        self.tools = tools ?? Self.bundledTools
        var environment = environment
        // Finder launches usually do not inherit Homebrew's PATH.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        self.environment = environment
        self.downloader = downloader
    }

    public static var bundledTools: URL {
        Bundle.module.url(forResource: "SteamBridge", withExtension: nil)!
    }

    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/Threshold XR/SteamBridgeBuilds")
    }

    public func snapshot() -> SteamBridgeBuildStatus {
        var copy = status
        if let url = status.logURL, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let end = try? handle.seekToEnd() {
                try? handle.seek(toOffset: end > 64 * 1024 ? end - 64 * 1024 : 0)
                if let bytes = try? handle.readToEnd() { copy.logTail = String(decoding: bytes, as: UTF8.self) }
            }
        }
        return copy
    }

    public func cancel() {
        guard busy else { return }
        cancelled = true
        status.phase = .cancelling
        current?.requestStop()
        download?.cancel()
    }

    public func run(_ request: SteamBridgeBuildRequest, checkOnly: Bool = false) async throws {
        guard !busy else { throw ReleaseError.invalid("A Steam bridge operation is already running.") }
        busy = true
        cancelled = false
        status = SteamBridgeBuildStatus()
        status.phase = .preparing
        defer { busy = false; current = nil; download = nil }
        do {
            try request.validate()
            let directory = root.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            status.directory = directory
            let sdk: URL
            switch request.sdk {
            case let .directory(url): sdk = url
            case let .archive(url, hash):
                sdk = directory.appending(path: "sdk")
                status.phase = .unpacking
                try await command(["unpack-sdk", "--archive", url.path, "--sha256", hash, "--output", sdk.path])
            case let .download(url, hash):
                status.phase = .downloading
                let archive = directory.appending(path: "sdk.tar.gz")
                let downloader = self.downloader
                let task = Task { try await downloader.download(url, to: archive, maximumSize: 512 * 1024 * 1024) }
                download = task
                try await task.value
                download = nil
                try checkCancellation()
                guard try ReleaseInstaller.fileDigest(archive) == hash else {
                    throw ReleaseError.invalid("Development bundle checksum failed. Nothing was extracted.")
                }
                sdk = directory.appending(path: "sdk")
                status.phase = .unpacking
                try await command(["unpack-sdk", "--archive", archive.path, "--sha256", hash, "--output", sdk.path])
            }
            status.phase = .checking
            try await command(["doctor", "--sdk", sdk.path])
            try await command(["verify-runtime", "--sdk", sdk.path, "--runtime", request.runtime.path])
            if checkOnly {
                status.phase = .ready
                status.message = "Build tools and runtime match the selected development bundle."
                return
            }
            status.phase = .building
            let bridge = directory.appending(path: "bridge")
            try await command(["build", "--sdk", sdk.path, "--runtime", request.runtime.path,
                               "--work", directory.appending(path: "work").path, "--output", bridge.path,
                               "--jobs", String(request.jobs)])
            status.phase = .staging
            let runtime = directory.appending(path: "runtime")
            try await command(["stage-runtime", "--sdk", sdk.path, "--runtime", request.runtime.path,
                               "--bridge", bridge.path, "--output", runtime.path])
            try checkCancellation()
            status.runtime = runtime
            status.phase = .complete
            status.message = "A separate runtime is ready. The selected runtime and game prefixes were not changed."
        } catch {
            status.phase = cancelled || error is CancellationError ? .cancelled : .failed
            status.message = error.localizedDescription
            throw error
        }
    }

    private func checkCancellation() throws {
        if cancelled || Task.isCancelled { throw CancellationError() }
    }

    private func command(_ arguments: [String]) async throws {
        try checkCancellation()
        guard let directory = status.directory else { throw ReleaseError.invalid("No build directory.") }
        let target = LaunchTarget(id: "steam-bridge-\(arguments[0])", title: arguments[0], url: URL(fileURLWithPath: "/usr/bin/env"),
                                  arguments: ["python3", tools.appending(path: "bridge.py").path] + arguments)
        let child = try ExecutableProcess.start(target, environment: environment,
                                                logDirectory: directory.appending(path: "logs"))
        current = child
        status.logURL = child.logURL
        let result = await child.waitForExit()
        current = nil
        try checkCancellation()
        guard result == .exited(0) else {
            let detail = snapshot().logTail.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReleaseError.invalid(detail.isEmpty ? "\(arguments[0]) failed with \(result.description)." : detail)
        }
    }
}
