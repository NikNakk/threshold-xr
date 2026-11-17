import Foundation
import CryptoKit
import CThresholdArchive

public protocol ReleaseDownloading: Sendable {
    /// Writes only a successful HTTPS response to destination.
    func download(_ url: URL, to destination: URL, maximumSize: Int64) async throws
}

public struct GitHubReleaseDownloader: ReleaseDownloading {
    private let timeoutInterval: TimeInterval
    public init(timeoutInterval: TimeInterval = 300) { self.timeoutInterval = timeoutInterval }
    public func download(_ url: URL, to destination: URL, maximumSize: Int64) async throws {
        var request = URLRequest(url: url)
        request.setValue("ThresholdXR", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeoutInterval
        let (temporary, response) = try await URLSession.shared.download(
            for: request, delegate: SizeLimitedDownload(maximumSize: maximumSize))
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, [403, 429].contains(http.statusCode) {
            throw ReleaseError.invalid("GitHub is limiting requests or denying access. Try checking again later.")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https" else {
            throw ReleaseError.invalid("GitHub could not supply \(url.lastPathComponent). The release may not be published yet.")
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, Int64(size) <= maximumSize else {
            throw ReleaseError.invalid("Downloaded asset exceeds its allowed size or is empty.")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

private final class SizeLimitedDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    let maximumSize: Int64
    init(maximumSize: Int64) { self.maximumSize = maximumSize }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumSize || totalBytesExpectedToWrite > maximumSize { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public struct InstalledReleaseStack: Identifiable, Sendable {
    public var stack: ReleaseStack
    public var directory: URL
    public var id: String { stack.id }
}

public struct InstalledComponentRelease: Sendable {
    public var release: ComponentRelease
    public var manifestSHA256: String
    public var directory: URL
}

/// Serializes installs in this app. A per-root file lock also excludes other app processes.
public actor ReleaseInstaller {
    public let root: URL
    private let downloader: any ReleaseDownloading
    private let fm = FileManager.default

    public init(root: URL, downloader: any ReleaseDownloading = GitHubReleaseDownloader()) {
        self.root = root
        self.downloader = downloader
    }

    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/Threshold XR/Components")
    }

    public func installedStacks() -> [InstalledReleaseStack] {
        let stacks = root.appending(path: "Stacks")
        return ((try? fm.contentsOfDirectory(at: stacks, includingPropertiesForKeys: nil)) ?? []).compactMap { directory in
            guard let bytes = try? Data(contentsOf: directory.appending(path: "stack.json")),
                  let stack = try? JSONDecoder().decode(ReleaseStack.self, from: bytes),
                  (try? stack.validate()) != nil, directory.lastPathComponent == stack.id else { return nil }
            return InstalledReleaseStack(stack: stack, directory: directory)
        }.sorted { $0.id < $1.id }
    }

    public func installedComponents() -> [InstalledComponentRelease] {
        ReleaseRepository.repositories.keys.sorted().flatMap { component in
            let parent = root.appending(path: component)
            return ((try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []).compactMap { directory -> InstalledComponentRelease? in
                guard let bytes = try? Data(contentsOf: directory.appending(path: "threshold-release.json")),
                      let release = try? JSONDecoder().decode(ComponentRelease.self, from: bytes),
                      release.component == component, release.version == directory.lastPathComponent else { return nil }
                let digest = ReleaseRepository.digest(bytes)
                let pin = ReleaseStack.Pin(component: component, repository: release.repository,
                                           tag: "threshold-" + release.version, manifestSHA256: digest)
                guard (try? release.validate(pin: pin)) != nil,
                      release.artifacts.allSatisfy({ artifact in
                          var isDirectory: ObjCBool = false
                          return fm.fileExists(atPath: directory.appending(path: artifact.platform).path, isDirectory: &isDirectory) && isDirectory.boolValue
                      }) else { return nil }
                return InstalledComponentRelease(release: release, manifestSHA256: digest, directory: directory)
            }
        }
    }

    /// Installs one verified build without creating a launch-stack selection.
    public func install(_ pin: ReleaseStack.Pin) async throws {
        let stack = ReleaseStack(schema: "threshold-xr/stack-1", id: UUID().uuidString,
                                 channel: "experimental", releases: [pin])
        _ = try await performInstall(stack, writeReceipt: false)
    }

    /// All manifests are verified before any archives are downloaded. The stack receipt
    /// appears only once every component has been installed successfully.
    @discardableResult
    public func install(_ stack: ReleaseStack) async throws -> InstalledReleaseStack {
        try await performInstall(stack, writeReceipt: true)
    }

    private func performInstall(_ stack: ReleaseStack, writeReceipt: Bool) async throws -> InstalledReleaseStack {
        try stack.validate()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = open(root.appending(path: ".install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw ReleaseError.invalid("Could not lock the component directory.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw ReleaseError.invalid("Another Threshold XR installation is in progress.")
        }
        let stackDirectory = root.appending(path: "Stacks/\(stack.id)")
        guard !fm.fileExists(atPath: stackDirectory.path) else {
            throw ReleaseError.invalid("Stack \(stack.id) is already installed. Use a new stack ID for a different set of releases.")
        }
        let staging = root.appending(path: ".install-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var releases: [(ReleaseStack.Pin, ComponentRelease, Data)] = []
        for pin in stack.releases {
            try Task.checkCancellation()
            let manifestURL = try ReleaseRepository.assetURL(repository: pin.repository, tag: pin.tag, name: "threshold-release.json")
            let local = staging.appending(path: "\(pin.component).json")
            try await downloader.download(manifestURL, to: local, maximumSize: 1024 * 1024)
            let bytes = try Data(contentsOf: local)
            guard ReleaseRepository.digest(bytes) == pin.manifestSHA256 else {
                throw ReleaseError.invalid("Release manifest checksum failed for \(pin.component). Nothing from this release was extracted.")
            }
            let release = try JSONDecoder().decode(ComponentRelease.self, from: bytes)
            try release.validate(pin: pin)
            releases.append((pin, release, bytes))
        }
        for (pin, release, manifest) in releases {
            let destination = root.appending(path: "\(release.component)/\(release.version)")
            if fm.fileExists(atPath: destination.path) {
                // Never overwrite a previous installation or a manual directory.
                guard (try? Data(contentsOf: destination.appending(path: "threshold-release.json"))) == manifest,
                      release.artifacts.allSatisfy({ artifact in
                          var directory: ObjCBool = false
                          return fm.fileExists(atPath: destination.appending(path: artifact.platform).path, isDirectory: &directory) && directory.boolValue
                      }) else {
                    throw ReleaseError.invalid("\(release.component) \(release.version) already exists with different or missing provenance.")
                }
                continue
            }
            let componentStage = staging.appending(path: release.component)
            try fm.createDirectory(at: componentStage, withIntermediateDirectories: true)
            for artifact in release.artifacts {
                try Task.checkCancellation()
                let archiveURL = staging.appending(path: artifact.name)
                let remote = try ReleaseRepository.assetURL(repository: pin.repository, tag: pin.tag, name: artifact.name)
                try await downloader.download(remote, to: archiveURL, maximumSize: artifact.size)
                let attributes = try fm.attributesOfItem(atPath: archiveURL.path)
                guard (attributes[.size] as? NSNumber)?.int64Value == artifact.size,
                      try Self.fileDigest(archiveURL) == artifact.sha256 else {
                    throw ReleaseError.invalid("Archive size or checksum failed for \(artifact.name).")
                }
                let platform = componentStage.appending(path: artifact.platform)
                try fm.createDirectory(at: platform, withIntermediateDirectories: true)
                try Self.extract(archiveURL, to: platform)
                try fm.removeItem(at: archiveURL)
            }
            if release.component == "monado" {
                guard let tag = release.provides["build_tag"] else { throw ReleaseError.invalid("Missing Monado build tag.") }
                for path in ["macos-arm64/bin/monado-service", "macos-x86_64/lib/libopenxr_monado.dylib"] {
                    let actual = FileProbe.firstEmbeddedString(in: componentStage.appending(path: path),
                                                              matching: NSRegularExpression.escapedPattern(for: tag))
                    guard actual == tag else {
                        throw ReleaseError.invalid("Monado's service and Wine client must embed the release build tag (\(tag)).")
                    }
                }
            }
            try manifest.write(to: componentStage.appending(path: "threshold-release.json"), options: .atomic)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: componentStage, to: destination)
        }
        if !writeReceipt { return InstalledReleaseStack(stack: stack, directory: root) }
        let receipt = staging.appending(path: "receipt")
        try fm.createDirectory(at: receipt, withIntermediateDirectories: true)
        try JSONEncoder().encode(stack).write(to: receipt.appending(path: "stack.json"))
        try fm.createDirectory(at: stackDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: receipt, to: stackDirectory)
        return InstalledReleaseStack(stack: stack, directory: stackDirectory)
    }

    public static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func extract(_ archive: URL, to directory: URL) throws {
        var error = [CChar](repeating: 0, count: 1024)
        let result = threshold_extract(archive.path, directory.resolvingSymlinksInPath().path, &error, error.count)
        guard result == 0 else {
            throw ReleaseError.invalid(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
    }
}
