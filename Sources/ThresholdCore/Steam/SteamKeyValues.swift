import Foundation

/// Valve's KeyValues: the text form (`.acf`, `.vdf`) and the binary form of
/// macOS Steam's app info cache (`appcache/appinfo.vdf`).
public indirect enum KeyValue: Sendable, Equatable {
    case string(String)
    case object([String: KeyValue])

    public subscript(key: String) -> KeyValue? {
        guard case let .object(values) = self else { return nil }
        // Keys are case-insensitive in Valve's files.
        return values[key] ?? values.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var children: [String: KeyValue] {
        if case let .object(values) = self { return values }
        return [:]
    }
}

public enum KeyValueError: Error, Equatable {
    case unexpectedEnd
    case unexpectedToken(String)
    case unsupportedAppInfo(UInt32)
    case malformedAppInfo
}

public enum KeyValues {
    /// Parses text KeyValues: quoted or bare tokens, `{ }` blocks and `//` comments.
    public static func parse(_ text: String) throws -> KeyValue {
        var tokens = Tokenizer(Array(text.unicodeScalars))
        var root: [String: KeyValue] = [:]
        while let key = try tokens.next() {
            guard case let .word(name) = key else { throw KeyValueError.unexpectedToken("}") }
            root[name] = try value(&tokens)
        }
        return .object(root)
    }

    private enum Token: Equatable { case word(String), open, close }

    private static func value(_ tokens: inout Tokenizer) throws -> KeyValue {
        guard let token = try tokens.next() else { throw KeyValueError.unexpectedEnd }
        switch token {
        case let .word(value): return .string(value)
        case .close: throw KeyValueError.unexpectedToken("}")
        case .open:
            var values: [String: KeyValue] = [:]
            while true {
                guard let next = try tokens.next() else { throw KeyValueError.unexpectedEnd }
                switch next {
                case .close: return .object(values)
                case .open: throw KeyValueError.unexpectedToken("{")
                case let .word(key): values[key] = try value(&tokens)
                }
            }
        }
    }

    private struct Tokenizer {
        let scalars: [Unicode.Scalar]
        var index = 0
        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func next() throws -> Token? {
            while index < scalars.count {
                let c = scalars[index]
                if CharacterSet.whitespacesAndNewlines.contains(c) { index += 1; continue }
                if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                    continue
                }
                // Conditionals such as [$WIN32] are ignored.
                if c == "[" {
                    while index < scalars.count, scalars[index] != "]" { index += 1 }
                    index += 1
                    continue
                }
                if c == "{" { index += 1; return .open }
                if c == "}" { index += 1; return .close }
                if c == "\"" {
                    index += 1
                    var out = String.UnicodeScalarView()
                    while index < scalars.count, scalars[index] != "\"" {
                        if scalars[index] == "\\", index + 1 < scalars.count {
                            index += 1
                            switch scalars[index] {
                            case "n": out.append("\n")
                            case "t": out.append("\t")
                            default: out.append(scalars[index])
                            }
                        } else {
                            out.append(scalars[index])
                        }
                        index += 1
                    }
                    guard index < scalars.count else { throw KeyValueError.unexpectedEnd }
                    index += 1
                    return .word(String(out))
                }
                var out = String.UnicodeScalarView()
                while index < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[index]),
                      !["{", "}", "\""].contains(scalars[index]) {
                    out.append(scalars[index])
                    index += 1
                }
                return .word(String(out))
            }
            return nil
        }
    }

    // MARK: appinfo.vdf

    /// The app info of the given apps from `appinfo.vdf` (formats 28 and 29), skipping the rest.
    public static func appInfo(_ data: Data, apps wanted: Set<UInt32>) throws -> [UInt32: KeyValue] {
        let bytes = [UInt8](data)
        var reader = ByteReader(bytes: bytes)
        let magic = try reader.u32()
        _ = try reader.u32() // universe
        var strings: [String]?
        var end = bytes.count
        switch magic {
        case 0x0756_4429:
            let table = Int(try reader.i64())
            guard table > 0, table < bytes.count else { throw KeyValueError.malformedAppInfo }
            var tableReader = ByteReader(bytes: bytes, position: table)
            let count = Int(try tableReader.u32())
            var list: [String] = []
            list.reserveCapacity(count)
            for _ in 0 ..< count { list.append(try tableReader.cString()) }
            strings = list
            end = table
        case 0x0756_4428:
            break
        default:
            throw KeyValueError.unsupportedAppInfo(magic)
        }

        var apps: [UInt32: KeyValue] = [:]
        while reader.position + 8 <= end {
            let appID = try reader.u32()
            if appID == 0 { break }
            let size = Int(try reader.u32())
            let next = reader.position + size
            guard next <= end else { throw KeyValueError.malformedAppInfo }
            if wanted.contains(appID) {
                // infostate, last updated, PICS token, SHA-1, change number, binary SHA-1
                var body = ByteReader(bytes: bytes, position: reader.position + 4 + 4 + 8 + 20 + 4 + 20)
                let info = try binaryObject(&body, strings: strings)
                apps[appID] = info["appinfo"] ?? info
            }
            reader.position = next
        }
        return apps
    }

    private static func binaryObject(_ reader: inout ByteReader, strings: [String]?) throws -> KeyValue {
        var values: [String: KeyValue] = [:]
        while true {
            let kind = try reader.u8()
            if kind == 0x08 { return .object(values) }
            let key: String
            if let strings {
                let index = Int(try reader.i32())
                guard strings.indices.contains(index) else { throw KeyValueError.malformedAppInfo }
                key = strings[index]
            } else {
                key = try reader.cString()
            }
            switch kind {
            case 0x00: values[key] = try binaryObject(&reader, strings: strings)
            case 0x01: values[key] = .string(try reader.cString())
            case 0x02: values[key] = .string(String(try reader.i32()))
            case 0x03: values[key] = .string(String(Float(bitPattern: try reader.u32())))
            case 0x07: values[key] = .string(String(try reader.u64()))
            default: throw KeyValueError.malformedAppInfo
            }
        }
    }

    private struct ByteReader {
        let bytes: [UInt8]
        var position = 0

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard position + count <= bytes.count else { throw KeyValueError.unexpectedEnd }
            defer { position += count }
            return bytes[position ..< position + count]
        }

        mutating func u8() throws -> UInt8 { try take(1).first! }
        mutating func u32() throws -> UInt32 { try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func u64() throws -> UInt64 { try take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) } }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }

        mutating func cString() throws -> String {
            guard let end = bytes[position...].firstIndex(of: 0) else { throw KeyValueError.unexpectedEnd }
            defer { position = end + 1 }
            return String(decoding: bytes[position ..< end], as: UTF8.self)
        }
    }
}
