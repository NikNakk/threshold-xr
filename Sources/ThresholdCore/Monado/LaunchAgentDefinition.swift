import Foundation

/// A per-user LaunchAgent property list, read without loss so it can be
/// written back with only the intended keys changed.
public struct LaunchAgentDefinition: Sendable, Equatable {
    public var url: URL
    /// The complete property list. Unknown keys are preserved on write.
    public var raw: [String: PlistValue]

    public init(url: URL, raw: [String: PlistValue]) {
        self.url = url
        self.raw = raw
    }

    public static func load(from url: URL) throws -> LaunchAgentDefinition {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        guard let dictionary = object as? [String: Any] else {
            throw LaunchAgentError.malformed(url)
        }
        return LaunchAgentDefinition(url: url, raw: dictionary.compactMapValues(PlistValue.init(any:)))
    }

    public var label: String? { raw["Label"]?.string }
    public var programArguments: [String] { raw["ProgramArguments"]?.array?.compactMap(\.string) ?? [] }
    public var program: String? { raw["Program"]?.string ?? programArguments.first }
    public var runAtLoad: Bool { raw["RunAtLoad"]?.bool ?? false }
    public var keepAlive: Bool { raw["KeepAlive"]?.bool ?? false }
    public var machServices: [String] { raw["MachServices"]?.dictionary.map { Array($0.keys).sorted() } ?? [] }
    public var standardOutPath: String? { raw["StandardOutPath"]?.string }
    public var standardErrorPath: String? { raw["StandardErrorPath"]?.string }

    public var environment: [String: String] {
        get { raw["EnvironmentVariables"]?.dictionary?.compactMapValues(\.string) ?? [:] }
        set { raw["EnvironmentVariables"] = .dictionary(newValue.mapValues(PlistValue.string)) }
    }

    /// XML property list data for this definition.
    public func serialized() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: raw.mapValues(\.any), format: .xml, options: 0)
    }
}

public enum LaunchAgentError: Error, LocalizedError, Sendable, Equatable {
    case malformed(URL)
    case backupFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .malformed(url): return "\(url.path) is not a valid LaunchAgent property list."
        case let .backupFailed(reason): return "Could not back up the LaunchAgent before changing it: \(reason)"
        case let .writeFailed(reason): return "Could not write the LaunchAgent: \(reason)"
        }
    }
}

/// Writes LaunchAgent changes safely: the existing file is copied to a
/// timestamped backup first, then replaced atomically.
public struct LaunchAgentWriter: Sendable {
    public var backupDirectory: URL

    public init(backupDirectory: URL) {
        self.backupDirectory = backupDirectory
    }

    /// Returns the backup's location.
    @discardableResult
    public func write(_ definition: LaunchAgentDefinition, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = backupDirectory.appending(path: formatter.string(from: now))
        let backup = folder.appending(path: definition.url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(at: definition.url, to: backup)
        } catch {
            throw LaunchAgentError.backupFailed(error.localizedDescription)
        }

        do {
            let data = try definition.serialized()
            // Validate before replacing the user's file.
            _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            try data.write(to: definition.url, options: .atomic)
        } catch {
            throw LaunchAgentError.writeFailed(error.localizedDescription)
        }
        return backup
    }
}

/// A Sendable mirror of property-list values.
public indirect enum PlistValue: Sendable, Equatable, Hashable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    public init?(any value: Any) {
        switch value {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if CFNumberIsFloatType(value) {
                self = .real(value.doubleValue)
            } else {
                self = .integer(value.intValue)
            }
        case let value as Date: self = .date(value)
        case let value as Data: self = .data(value)
        case let value as [Any]: self = .array(value.compactMap(PlistValue.init(any:)))
        case let value as [String: Any]: self = .dictionary(value.compactMapValues(PlistValue.init(any:)))
        default: return nil
        }
    }

    public var any: Any {
        switch self {
        case let .string(value): return value
        case let .bool(value): return value
        case let .integer(value): return value
        case let .real(value): return value
        case let .date(value): return value
        case let .data(value): return value
        case let .array(value): return value.map(\.any)
        case let .dictionary(value): return value.mapValues(\.any)
        }
    }

    public var string: String? { if case let .string(v) = self { v } else { nil } }
    public var bool: Bool? { if case let .bool(v) = self { v } else { nil } }
    public var array: [PlistValue]? { if case let .array(v) = self { v } else { nil } }
    public var dictionary: [String: PlistValue]? { if case let .dictionary(v) = self { v } else { nil } }
}
