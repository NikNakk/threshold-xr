import Foundation

/// The component selections of the native Alyx `play` profile.
///
/// `run-alyx-profile` is the authoritative record of which KosmicKrisp ICD,
/// xrizer library and Alyx host the working configuration uses. Reading it
/// lets discovery report what is actually used instead of guessing among the
/// many development builds in the workspace. Nothing is executed.
public struct AlyxLaunchProfile: Sendable, Equatable {
    public var scriptURL: URL
    /// Option → value pairs from the `CURRENT_PLAY` list, e.g. `--kk-icd`.
    public var options: [String: String]

    public static func load(workspace root: URL) -> AlyxLaunchProfile? {
        let script = root.appending(path: "run-alyx-profile")
        guard let text = try? String(contentsOf: script, encoding: .utf8) else { return nil }
        return AlyxLaunchProfile(scriptURL: script, options: parse(text))
    }

    /// Extracts `'--option', 'value'` pairs from the `CURRENT_PLAY = [...]`
    /// assignment. Returns an empty dictionary if the layout changes.
    public static func parse(_ text: String) -> [String: String] {
        guard let start = text.range(of: "CURRENT_PLAY = [") else { return [:] }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return [:] }
        let body = String(rest[..<end])
        let tokens = body
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { token -> String? in
                guard token.count >= 2, let first = token.first, first == token.last, first == "'" || first == "\"" else {
                    return nil
                }
                return String(token.dropFirst().dropLast())
            }
        var options: [String: String] = [:]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--"), index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                options[token] = tokens[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        return options
    }

    /// A profile path, resolved against the workspace like the script does.
    public func url(for option: String) -> URL? {
        guard let value = options[option] else { return nil }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        return scriptURL.deletingLastPathComponent().appending(path: value)
    }

    public static let kosmicKrispICD = "--kk-icd"
    public static let xrizerLibrary = "--gaze-xrizer-library"
    public static let host = "--gaze-host"
}
