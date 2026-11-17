import Foundation
import CryptoKit

public enum ReleaseError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// The allowlist is independent of data downloaded from a release.
public enum ReleaseRepository {
    public static let repositories = [
        "monado": "NikNakk/monado", "kosmickrisp": "NikNakk/mesa",
        "xrizer": "NikNakk/xrizer", "klepton": "NikNakk/Klepton",
        "dxmt": "NikNakk/dxmt", "wine": "NikNakk/wine-crossover",
        "macos-wine-xr": "NikNakk/macos-wine-xr",
    ]

    static func token(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && value != "." && value != ".." &&
        value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || [45, 46, 95].contains($0) }
    }

    public static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func assetURL(repository: String, tag: String, name: String) throws -> URL {
        guard repositories.values.contains(repository), token(tag), token(name) else {
            throw ReleaseError.invalid("Unsupported repository, tag or asset name.")
        }
        return URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(name)")!
    }
}

public struct ReleaseStack: Codable, Sendable {
    public var schema: String
    public var id: String
    public var channel: String
    public var releases: [Pin]

    public struct Pin: Codable, Sendable {
        public var component: String
        public var repository: String
        public var tag: String
        public var manifestSHA256: String
        enum CodingKeys: String, CodingKey {
            case component, repository, tag
            case manifestSHA256 = "manifest_sha256"
        }
    }

    public func validate() throws {
        guard schema == "threshold-xr/stack-1", ReleaseRepository.token(id),
              ["stable", "experimental", "local"].contains(channel), !releases.isEmpty,
              Set(releases.map(\.component)).count == releases.count else {
            throw ReleaseError.invalid("Unsupported or malformed Threshold XR stack.")
        }
        for pin in releases {
            guard ReleaseRepository.repositories[pin.component] == pin.repository,
                  ReleaseRepository.token(pin.tag), pin.tag.hasPrefix("threshold-"),
                  ReleaseRepository.isDigest(pin.manifestSHA256) else {
                throw ReleaseError.invalid("Invalid release pin for \(pin.component).")
            }
        }
    }
}

public struct ComponentRelease: Codable, Sendable {
    public var schema: String
    public var component: String
    public var version: String
    public var repository: String
    public var commit: String
    public var built: String
    public var workflowRun: String
    public var provides: [String: String]
    public var artifacts: [Artifact]

    enum CodingKeys: String, CodingKey {
        case schema, component, version, repository, commit, built, provides, artifacts
        case workflowRun = "workflow_run"
    }

    public struct Artifact: Codable, Sendable {
        public var name: String
        public var platform: String
        public var sha256: String
        public var size: Int64
        public var role: String
    }

    public func validate(pin: ReleaseStack.Pin) throws {
        guard schema == "threshold-xr/release-1", component == pin.component,
              repository == pin.repository, ReleaseRepository.token(version),
              pin.tag == "threshold-" + version,
              commit.count == 40, commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              ISO8601DateFormatter().date(from: built) != nil,
              workflowRun.hasPrefix("https://github.com/\(repository)/actions/runs/"),
              !artifacts.isEmpty,
              Set(artifacts.map(\.platform)).count == artifacts.count,
              Set(artifacts.map(\.name)).count == artifacts.count else {
            throw ReleaseError.invalid("Release identity or provenance does not match its stack pin.")
        }
        for artifact in artifacts {
            guard ["macos-arm64", "macos-x86_64", "windows-x86_64"].contains(artifact.platform),
                  artifact.name == "\(component)-\(version)-\(artifact.platform).tar.xz",
                  ReleaseRepository.isDigest(artifact.sha256), artifact.size > 0,
                  artifact.size <= 8 * 1024 * 1024 * 1024, !artifact.role.isEmpty else {
                throw ReleaseError.invalid("Invalid artifact in \(component) release.")
            }
        }
        let requiredPlatforms: [String: Set<String>] = [
            "monado": ["macos-arm64", "macos-x86_64"], "kosmickrisp": ["macos-arm64"],
            "xrizer": ["macos-arm64", "windows-x86_64"], "klepton": ["macos-arm64"],
            "dxmt": ["macos-x86_64", "windows-x86_64"], "wine": ["macos-x86_64"],
            "macos-wine-xr": ["macos-arm64", "windows-x86_64"],
        ]
        guard requiredPlatforms[component] == Set(artifacts.map(\.platform)) else {
            throw ReleaseError.invalid("The release is missing required platforms for \(component).")
        }
        if component == "monado" {
            guard provides["build_tag"]?.isEmpty == false,
                  artifacts.contains(where: { $0.platform == "macos-arm64" && $0.role == "service" }),
                  artifacts.contains(where: { $0.platform == "macos-x86_64" && $0.role == "wine-client" }) else {
                throw ReleaseError.invalid("Monado requires both architectures from the same build tag.")
            }
        }
    }
}
