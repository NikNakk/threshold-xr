import Foundation

/// Threshold XR's own preferences, stored in `UserDefaults` (the app's
/// preferences domain, `~/Library/Preferences/<bundle id>.plist`).
public final class AppPreferences: @unchecked Sendable {
    public enum Key {
        public static let automaticRuntimeQueries = "automaticRuntimeQueries"
        public static let refreshInterval = "refreshInterval"
        public static let workspaceRoot = "workspaceRoot"
        public static let windowsRigRoot = "windowsRigRoot"
        public static let pathOverrides = "componentPathOverrides"
        public static let showAdvancedSettings = "showAdvancedSettings"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func value(for descriptor: SettingDescriptor) -> SettingValue? {
        guard case let .appPreferences(key) = descriptor.storage, let object = defaults.object(forKey: key) else {
            return nil
        }
        switch descriptor.type {
        case .toggle: return (object as? Bool).map(SettingValue.bool)
        case .integer: return (object as? Int).map(SettingValue.integer)
        case .decimal: return (object as? Double).map(SettingValue.decimal)
        default: return (object as? String).map(SettingValue.text)
        }
    }

    /// The stored value, or the descriptor's default.
    public func effectiveValue(for descriptor: SettingDescriptor) -> SettingValue? {
        value(for: descriptor) ?? descriptor.defaultValue
    }

    public func set(_ value: SettingValue?, for descriptor: SettingDescriptor) throws {
        guard case let .appPreferences(key) = descriptor.storage else {
            throw SettingsError.wrongStore(descriptor.id)
        }
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        if let problem = descriptor.validate(value) { throw SettingsError.invalid(problem) }
        switch value {
        case let .bool(v): defaults.set(v, forKey: key)
        case let .integer(v): defaults.set(v, forKey: key)
        case let .decimal(v): defaults.set(v, forKey: key)
        case let .text(v): defaults.set(v, forKey: key)
        }
    }

    public var automaticRuntimeQueries: Bool {
        effectiveValue(for: descriptor(Key.automaticRuntimeQueries))?.bool ?? true
    }

    public var refreshInterval: TimeInterval {
        TimeInterval(effectiveValue(for: descriptor(Key.refreshInterval))?.integer ?? 3)
    }

    public var workspaceRoot: String {
        effectiveValue(for: descriptor(Key.workspaceRoot))?.text ?? "~/Code"
    }

    public var windowsRigRoot: String {
        effectiveValue(for: descriptor(Key.windowsRigRoot))?.text ?? "~/Windows"
    }

    public var showAdvancedSettings: Bool {
        get { defaults.bool(forKey: Key.showAdvancedSettings) }
        set { defaults.set(newValue, forKey: Key.showAdvancedSettings) }
    }

    /// Per-component detection path overrides.
    public var pathOverrides: [String: String] {
        get { defaults.dictionary(forKey: Key.pathOverrides) as? [String: String] ?? [:] }
        set {
            let cleaned = newValue.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            defaults.set(cleaned, forKey: Key.pathOverrides)
        }
    }

    public func setPathOverride(_ path: String?, for id: ComponentID) {
        var overrides = pathOverrides
        overrides[id.rawValue] = path
        pathOverrides = overrides
    }

    private func descriptor(_ id: String) -> SettingDescriptor {
        // Every Key used above is in the catalog; a missing one is a programming error.
        SettingsCatalog.app.first { $0.id == id }!
    }
}

public enum SettingsError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)
    case wrongStore(String)
    case monadoAgentMissing(String)
    case agentChangedOnDisk

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): return message
        case let .wrongStore(id): return "\(id) is not stored here."
        case let .monadoAgentMissing(path): return "Monado's LaunchAgent was not found at \(path). Monado settings are stored there."
        case .agentChangedOnDisk: return "Monado's LaunchAgent changed on disk since it was read. Review the current values and try again."
        }
    }
}

/// The current value of one Monado setting, as found in the LaunchAgent.
public struct MonadoSettingValue: Sendable, Equatable {
    public var descriptor: SettingDescriptor
    /// Raw string in the plist, or `nil` when absent (Monado's default).
    public var raw: String?
    public var value: SettingValue?
    /// Whether launchd has the job loaded, so `loadedRaw` is meaningful.
    public var isLoaded: Bool
    /// The value in the loaded job's environment (`nil` when absent).
    public var loadedRaw: String?
    /// Whether the installed `monado-service` reads this variable at all.
    public var recognisedByInstalledService: Bool?

    public var isSet: Bool { raw != nil }
    public var effectiveValue: SettingValue? { value ?? descriptor.defaultValue }
    /// The saved value differs from what the running service is using.
    public var isPendingReload: Bool { isLoaded && loadedRaw != raw }
}

/// Reads and writes Monado's settings in their existing home, the service
/// LaunchAgent's `EnvironmentVariables`. No copy is kept elsewhere, so there
/// is no second source of truth. Writes keep a backup and only touch the
/// variables being changed.
public struct MonadoSettingsStore: Sendable {
    public var agentURL: URL
    public var writer: LaunchAgentWriter
    public var descriptors: [SettingDescriptor]

    public init(agentURL: URL, backupDirectory: URL, descriptors: [SettingDescriptor] = SettingsCatalog.monado) {
        self.agentURL = agentURL
        self.writer = LaunchAgentWriter(backupDirectory: backupDirectory)
        self.descriptors = descriptors
    }

    public func read(loadedEnvironment: [String: String]? = nil, serviceExecutable: URL? = nil) throws -> [MonadoSettingValue] {
        guard FileProbe.exists(agentURL) else { throw SettingsError.monadoAgentMissing(agentURL.path) }
        let environment = try LaunchAgentDefinition.load(from: agentURL).environment
        let variables = Set(descriptors.compactMap(\.environmentVariable))
        let recognised = serviceExecutable.map { FileProbe.containsEmbeddedStrings(variables, in: $0) }
        return descriptors.compactMap { descriptor in
            guard let variable = descriptor.environmentVariable else { return nil }
            let raw = environment[variable]
            return MonadoSettingValue(
                descriptor: descriptor,
                raw: raw,
                value: raw.flatMap(descriptor.decodeFromEnvironment),
                isLoaded: loadedEnvironment != nil,
                loadedRaw: loadedEnvironment?[variable],
                recognisedByInstalledService: recognised.map { $0.contains(variable) }
            )
        }
    }

    /// Applies changes (`nil` removes the variable so Monado's default
    /// applies). Returns the backup location. The running service is not
    /// affected until the LaunchAgent is reloaded.
    @discardableResult
    public func write(_ changes: [String: SettingValue?], expectedModificationDate: Date? = nil) throws -> URL {
        guard FileProbe.exists(agentURL) else { throw SettingsError.monadoAgentMissing(agentURL.path) }
        if let expected = expectedModificationDate, let current = FileProbe.modificationDate(agentURL),
           abs(current.timeIntervalSince(expected)) > 0.001 {
            throw SettingsError.agentChangedOnDisk
        }
        var definition = try LaunchAgentDefinition.load(from: agentURL)
        var environment = definition.environment
        for (id, value) in changes {
            guard let descriptor = descriptors.first(where: { $0.id == id }),
                  let variable = descriptor.environmentVariable else {
                throw SettingsError.wrongStore(id)
            }
            if let value {
                if let problem = descriptor.validate(value) { throw SettingsError.invalid(problem) }
                environment[variable] = descriptor.encodeForEnvironment(value)
            } else {
                environment.removeValue(forKey: variable)
            }
        }
        definition.environment = environment
        return try writer.write(definition)
    }
}
