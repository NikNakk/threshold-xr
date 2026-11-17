import Foundation

public struct WineKitRelease: Codable, Sendable, Equatable {
    public struct Archive: Codable, Sendable, Equatable {
        public var name: String
        public var sha256: String
        public var size: Int64
    }
    public var schema: String
    public var id: String
    public var title: String
    public var downloadURL: URL
    public var runtime: Archive
    public var sdk: Archive
    public var runtimeFiles: [String: String]
    enum CodingKeys: String, CodingKey {
        case schema, id, title, runtime, sdk
        case downloadURL = "download_url", runtimeFiles = "runtime_files"
    }

    public static func prototype() throws -> Self {
        guard let url = Bundle.module.url(forResource: "prototype", withExtension: "json", subdirectory: "WineKit") else {
            throw ReleaseError.invalid("The bundled Wine package description is missing.")
        }
        let kit = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try kit.validate()
        return kit
    }

    public func validate() throws {
        let paths: Set<String> = ["lib/wine/i386-windows/ntdll.dll", "lib/wine/x86_64-windows/ntdll.dll",
                                  "lib/wine/x86_64-unix/ntdll.so"]
        guard schema == "threshold-xr/wine-kit-1", ReleaseRepository.token(id),
              downloadURL.scheme == "https", downloadURL.host == "github.com",
              Set(runtimeFiles.keys) == paths, runtimeFiles.values.allSatisfy(ReleaseRepository.isDigest) else {
            throw ReleaseError.invalid("Unsupported Wine package description.")
        }
        for archive in [runtime, sdk] {
            guard ReleaseRepository.token(archive.name), ReleaseRepository.isDigest(archive.sha256),
                  archive.size > 0, archive.size <= 8 * 1024 * 1024 * 1024 else {
                throw ReleaseError.invalid("Invalid Wine package identity.")
            }
        }
    }
}

public struct InstalledWineKit: Sendable {
    public var release: WineKitRelease
    public var directory: URL
    public var runtime: URL { directory.appending(path: "runtime") }
    public var sdkArchive: URL { directory.appending(path: release.sdk.name) }
}

/// Imports a known CI kit using identities bundled with the app. No compiler or
/// interpreter is used to prepare packaged Wine; the SDK archive is kept for later.
public actor WineKitInstaller {
    private let root: URL
    private let release: WineKitRelease
    private let fm = FileManager.default

    public init(root: URL, release: WineKitRelease) {
        self.root = root
        self.release = release
    }

    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/Threshold XR/WinePackages")
    }

    public func installed() throws -> InstalledWineKit? {
        try release.validate()
        let directory = root.appending(path: release.id)
        guard fm.fileExists(atPath: directory.path) else { return nil }
        let saved = try JSONDecoder().decode(WineKitRelease.self, from: Data(contentsOf: directory.appending(path: "kit.json")))
        guard saved == release else { throw ReleaseError.invalid("The installed Wine package has a different identity.") }
        let result = InstalledWineKit(release: release, directory: directory)
        try verifyRuntime(result.runtime)
        try verifyArchive(result.sdkArchive, release.sdk)
        return result
    }

    public func install(from folder: URL) throws -> InstalledWineKit {
        try release.validate()
        if let result = try installed() { return result }
        let runtimeArchive = folder.appending(path: release.runtime.name)
        let sdkArchive = folder.appending(path: release.sdk.name)
        // Verify both against the app's trusted metadata, rather than a downloaded
        // checksum sidecar, before extracting or running anything.
        try verifyArchive(runtimeArchive, release.runtime)
        try verifyArchive(sdkArchive, release.sdk)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = open(root.appending(path: ".install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw ReleaseError.invalid("Could not lock the Wine package directory.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ReleaseError.invalid("Another Wine package import is running.") }
        if let result = try installed() { return result }
        let staging = root.appending(path: ".import-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let runtime = staging.appending(path: "runtime")
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        try ReleaseInstaller.extract(runtimeArchive, to: runtime)
        try verifyRuntime(runtime)
        try fm.copyItem(at: sdkArchive, to: staging.appending(path: release.sdk.name))
        try JSONEncoder().encode(release).write(to: staging.appending(path: "kit.json"), options: .atomic)
        let destination = root.appending(path: release.id)
        try fm.moveItem(at: staging, to: destination)
        return InstalledWineKit(release: release, directory: destination)
    }

    private func verifyArchive(_ path: URL, _ expected: WineKitRelease.Archive) throws {
        guard let attributes = try? fm.attributesOfItem(atPath: path.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == expected.size,
              try ReleaseInstaller.fileDigest(path) == expected.sha256 else {
            throw ReleaseError.invalid("Missing or changed \(expected.name). Choose the folder extracted from the matching GitHub build download.")
        }
    }

    private func verifyRuntime(_ runtime: URL) throws {
        let resolved = runtime.resolvingSymlinksInPath().path + "/"
        for (name, expected) in release.runtimeFiles {
            let path = runtime.appending(path: name)
            guard path.resolvingSymlinksInPath().path.hasPrefix(resolved),
                  (try? ReleaseInstaller.fileDigest(path)) == expected else {
                throw ReleaseError.invalid("Wine package identity check failed for \(name).")
            }
        }
        guard fm.isExecutableFile(atPath: runtime.appending(path: "bin/wine").path),
              fm.isExecutableFile(atPath: runtime.appending(path: "bin/wineserver").path) else {
            throw ReleaseError.invalid("The package does not contain a runnable Wine installation.")
        }
    }
}
