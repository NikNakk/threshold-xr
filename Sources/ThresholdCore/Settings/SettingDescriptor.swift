import Foundation

/// A setting's value. Settings that are absent use the owning component's
/// own default, represented as `nil` rather than a copied default value.
public enum SettingValue: Sendable, Equatable, Hashable, Codable {
    case bool(Bool)
    case integer(Int)
    case decimal(Double)
    case text(String)

    public var bool: Bool? { if case let .bool(v) = self { v } else { nil } }
    public var integer: Int? { if case let .integer(v) = self { v } else { nil } }
    public var decimal: Double? {
        switch self {
        case let .decimal(v): return v
        case let .integer(v): return Double(v)
        default: return nil
        }
    }
    public var text: String? { if case let .text(v) = self { v } else { nil } }

    public var displayString: String {
        switch self {
        case let .bool(v): return v ? "On" : "Off"
        case let .integer(v): return String(v)
        case let .decimal(v): return SettingValue.format(v)
        case let .text(v): return v
        }
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e9 { return String(Int(value)) }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

public struct SettingChoice: Sendable, Equatable, Hashable {
    public var value: SettingValue
    public var title: String

    public init(_ value: SettingValue, _ title: String) {
        self.value = value
        self.title = title
    }
}

public enum SettingType: Sendable, Equatable {
    case toggle
    case integer(range: ClosedRange<Int>, unit: String?)
    case decimal(range: ClosedRange<Double>, step: Double, unit: String?)
    case choice([SettingChoice])
    case filePath(allowedExtensions: [String])
    case directoryPath
    case text
}

/// When a changed value takes effect.
public enum SettingApplyMode: String, Sendable, Equatable {
    /// Immediately, in the running app.
    case live = "Applies immediately"
    /// After Monado's LaunchAgent is reloaded. launchd reads a job's
    /// environment only when it is loaded, and Monado reads these variables
    /// once at startup.
    case serviceReload = "Requires service reload"
    /// The next time an application starts.
    case nextClientLaunch = "Applies to newly started applications"
}

/// Who owns the value. Monado's settings stay in Monado's own configuration
/// (its LaunchAgent environment); Threshold XR only edits them on request.
public enum SettingOwner: Sendable, Equatable, Hashable {
    case thresholdXR
    case component(ComponentID)

    public var displayName: String {
        switch self {
        case .thresholdXR: return "Threshold XR"
        case let .component(id): return id.displayName
        }
    }
}

/// Where the value is stored.
public enum SettingStorage: Sendable, Equatable, Hashable {
    /// Threshold XR's own preferences (`UserDefaults`).
    case appPreferences(key: String)
    /// A variable in Monado's service LaunchAgent `EnvironmentVariables`,
    /// the configuration Monado's own `monado-service-xpc-control install`
    /// and local preference scripts preserve.
    case monadoServiceEnvironment(variable: String)
}

public struct SettingDescriptor: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var group: String
    public var owner: SettingOwner
    public var storage: SettingStorage
    public var type: SettingType
    /// The value the owner uses when the setting is absent, for display and
    /// "reset". `nil` means there is no single default (for example a path).
    public var defaultValue: SettingValue?
    public var applyMode: SettingApplyMode
    public var isAdvanced: Bool
    public var isDeveloper: Bool

    public init(
        id: String,
        title: String,
        detail: String,
        group: String,
        owner: SettingOwner,
        storage: SettingStorage,
        type: SettingType,
        defaultValue: SettingValue?,
        applyMode: SettingApplyMode,
        isAdvanced: Bool = false,
        isDeveloper: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.group = group
        self.owner = owner
        self.storage = storage
        self.type = type
        self.defaultValue = defaultValue
        self.applyMode = applyMode
        self.isAdvanced = isAdvanced
        self.isDeveloper = isDeveloper
    }

    public var canChangeLive: Bool { applyMode == .live }
    public var requiresServiceRestart: Bool { applyMode == .serviceReload }

    public var environmentVariable: String? {
        if case let .monadoServiceEnvironment(variable) = storage { variable } else { nil }
    }

    // MARK: Validation and encoding

    public func validate(_ value: SettingValue) -> String? {
        switch (type, value) {
        case (.toggle, .bool): return nil
        case let (.integer(range, unit), .integer(v)):
            return range.contains(v) ? nil : "\(title) must be between \(range.lowerBound) and \(range.upperBound)\(unit.map { " \($0)" } ?? "")."
        case let (.decimal(range, _, unit), _):
            guard let v = value.decimal else { return "\(title) must be a number." }
            return range.contains(v) ? nil : "\(title) must be between \(SettingValue.format(range.lowerBound)) and \(SettingValue.format(range.upperBound))\(unit.map { " \($0)" } ?? "")."
        case let (.choice(choices), _):
            return choices.contains { $0.value == value } ? nil : "\(value.displayString) is not a valid choice for \(title)."
        case (.filePath, .text(let path)), (.directoryPath, .text(let path)):
            return path.isEmpty ? "\(title) cannot be empty; reset it instead." : nil
        case (.text, .text): return nil
        default: return "\(title) has the wrong kind of value."
        }
    }

    /// The value as an environment-variable string, in the form Monado's
    /// `debug_get_*_option` parsers accept.
    public func encodeForEnvironment(_ value: SettingValue) -> String {
        switch value {
        case let .bool(v): return v ? "1" : "0"
        case let .integer(v): return String(v)
        case let .decimal(v): return SettingValue.format(v)
        case let .text(v): return v
        }
    }

    /// Parses an environment string. Returns `nil` for unparsable values so
    /// the UI can show the raw text instead of guessing.
    public func decodeFromEnvironment(_ raw: String) -> SettingValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        switch type {
        case .toggle:
            switch trimmed.lowercased() {
            case "1", "true", "yes", "on", "y": return .bool(true)
            case "0", "false", "no", "off", "n", "": return .bool(false)
            default: return nil
            }
        case .integer:
            return Int(trimmed).map(SettingValue.integer)
        case .decimal:
            return Double(trimmed).map(SettingValue.decimal)
        case let .choice(choices):
            return choices.first { encodeForEnvironment($0.value) == trimmed }?.value
                ?? Int(trimmed).map(SettingValue.integer)
        case .filePath, .directoryPath, .text:
            return .text(raw)
        }
    }
}
