import Foundation

/// Branch and commit of a source checkout, read directly from `.git` without
/// running git or touching the index.
public struct GitCheckoutInfo: Sendable, Equatable, Hashable {
    public var root: URL
    public var branch: String?
    public var commit: String?

    public var shortCommit: String? { commit.map { String($0.prefix(9)) } }

    public var summary: String {
        switch (branch, shortCommit) {
        case let (branch?, commit?): return "\(branch) @ \(commit)"
        case let (nil, commit?): return "detached @ \(commit)"
        case let (branch?, nil): return branch
        default: return "unknown revision"
        }
    }

    public static func read(at root: URL) -> GitCheckoutInfo? {
        var gitDir = root.appending(path: ".git")
        if !FileProbe.isDirectory(gitDir) {
            // Worktrees and submodules use a `.git` file: "gitdir: <path>".
            guard let text = try? String(contentsOf: gitDir, encoding: .utf8),
                  text.hasPrefix("gitdir:") else { return nil }
            let path = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appending(path: path)
        }
        guard let head = try? String(contentsOf: gitDir.appending(path: "HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        if head.hasPrefix("ref: ") {
            let ref = String(head.dropFirst(5))
            let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            return GitCheckoutInfo(root: root, branch: branch, commit: resolve(ref: ref, gitDir: gitDir))
        }
        return GitCheckoutInfo(root: root, branch: nil, commit: head)
    }

    private static func resolve(ref: String, gitDir: URL) -> String? {
        // Linked worktrees keep shared refs in the common directory.
        var dirs = [gitDir]
        if let common = try? String(contentsOf: gitDir.appending(path: "commondir"), encoding: .utf8) {
            let path = common.trimmingCharacters(in: .whitespacesAndNewlines)
            dirs.append(path.hasPrefix("/") ? URL(fileURLWithPath: path) : gitDir.appending(path: path))
        }
        for dir in dirs {
            if let loose = try? String(contentsOf: dir.appending(path: ref), encoding: .utf8) {
                return loose.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let packed = try? String(contentsOf: dir.appending(path: "packed-refs"), encoding: .utf8) {
                for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
                    return String(line.split(separator: " ").first ?? "")
                }
            }
        }
        return nil
    }
}
