import Foundation

/// Small read-only filesystem helpers used by discovery.
public enum FileProbe {
    public static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func isExecutableFile(_ url: URL) -> Bool {
        !isDirectory(url) && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Whether the path exists and is a Unix-domain socket.
    public static func isSocket(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }

    /// Follows every symbolic link in the path.
    public static func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }

    /// The destination of a symbolic link, if `url` itself is one.
    public static func symlinkDestination(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    public static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Returns the first existing URL.
    public static func firstExisting(_ candidates: [URL]) -> URL? {
        candidates.first(where: exists)
    }

    public static func directoryContents(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// Reads up to `maxBytes` from the end of a file, starting at a line boundary.
    public static func tail(_ url: URL, maxBytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    /// Finds the first match of `pattern` among the printable strings of a
    /// binary, like `strings | grep`. Used to read embedded build tags without
    /// executing the binary.
    public static func firstEmbeddedString(in url: URL, matching pattern: String, maxBytes: Int = 64 * 1024 * 1024) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let limit = min(data.count, maxBytes)
        var current = [UInt8]()
        current.reserveCapacity(128)

        func check() -> String? {
            defer { current.removeAll(keepingCapacity: true) }
            guard current.count >= 6 else { return nil }
            let string = String(decoding: current, as: UTF8.self)
            let range = NSRange(string.startIndex..., in: string)
            guard let match = regex.firstMatch(in: string, range: range),
                  let swiftRange = Range(match.range, in: string) else { return nil }
            return String(string[swiftRange])
        }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            for index in 0..<limit {
                let byte = raw[index]
                if byte >= 0x20 && byte < 0x7f {
                    current.append(byte)
                } else if let found = check() {
                    return found
                }
            }
            return check()
        }
    }

    /// Whether a binary contains an exact printable string (for example an
    /// environment-variable name it reads).
    public static func containsEmbeddedStrings(_ needles: Set<String>, in url: URL) -> Set<String> {
        guard !needles.isEmpty, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var found = Set<String>()
        var current = [UInt8]()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                if byte >= 0x20 && byte < 0x7f {
                    current.append(byte)
                } else {
                    if current.count >= 3 {
                        let string = String(decoding: current, as: UTF8.self)
                        if needles.contains(string) { found.insert(string) }
                    }
                    current.removeAll(keepingCapacity: true)
                }
            }
        }
        return found
    }
}
