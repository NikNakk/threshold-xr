import Foundation
import Testing
@testable import ThresholdCore

@Suite("Setting descriptors")
struct SettingDescriptorTests {
    let eyeHeight = SettingsCatalog.monado.first { $0.id == "monado.floorEyeHeight" }!
    let refresh = SettingsCatalog.monado.first { $0.id == "monado.refreshRate" }!
    let align = SettingsCatalog.monado.first { $0.id == "monado.floorAlign" }!

    @Test func catalogMetadataIsComplete() {
        let ids = SettingsCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count, "setting ids are unique")
        for descriptor in SettingsCatalog.monado {
            #expect(descriptor.owner == .component(.monado))
            #expect(descriptor.environmentVariable != nil)
            #expect(descriptor.requiresServiceRestart, "Monado reads its environment once at startup")
            #expect(!descriptor.canChangeLive)
        }
        for descriptor in SettingsCatalog.app {
            #expect(descriptor.owner == .thresholdXR)
            #expect(descriptor.canChangeLive)
        }
    }

    @Test func validatesRangesAndChoices() {
        #expect(eyeHeight.validate(.decimal(1.72)) == nil)
        #expect(eyeHeight.validate(.decimal(3.5)) != nil)
        #expect(refresh.validate(.integer(120)) == nil)
        #expect(refresh.validate(.integer(75)) != nil)
        #expect(align.validate(.integer(1)) != nil)
    }

    @Test func encodesForMonadoEnvironmentParsers() {
        #expect(align.encodeForEnvironment(.bool(true)) == "1")
        #expect(align.encodeForEnvironment(.bool(false)) == "0")
        #expect(eyeHeight.encodeForEnvironment(.decimal(1.72)) == "1.72")
        #expect(eyeHeight.encodeForEnvironment(.decimal(2)) == "2")
        #expect(refresh.encodeForEnvironment(.integer(90)) == "90")
    }

    @Test func decodesEnvironmentValues() {
        #expect(align.decodeFromEnvironment("1") == .bool(true))
        #expect(align.decodeFromEnvironment("false") == .bool(false))
        #expect(align.decodeFromEnvironment("maybe") == nil)
        #expect(eyeHeight.decodeFromEnvironment("1.72") == .decimal(1.72))
        #expect(refresh.decodeFromEnvironment("120") == .integer(120))
    }
}

@Suite("Monado settings store")
struct MonadoSettingsStoreTests {
    @Test func readsCurrentValuesAndInstalledSupport() throws {
        let home = try TemporaryDirectory()
        let agent = try makeMonadoInstall(in: home, environment: ["XRT_FLOOR_EYE_HEIGHT_M": "1.72", "XRT_FLOOR_ALIGN": "1"])
        let store = MonadoSettingsStore(agentURL: agent, backupDirectory: home.url.appending(path: "backups"))
        let install = MonadoInstallation.discover(context: home.context())
        let values = try store.read(loadedEnvironment: ["XRT_FLOOR_EYE_HEIGHT_M": "1.60", "XRT_FLOOR_ALIGN": "1"],
                                    serviceExecutable: install.serviceExecutable)

        let eye = try #require(values.first { $0.descriptor.id == "monado.floorEyeHeight" })
        #expect(eye.value == .decimal(1.72))
        #expect(eye.isPendingReload, "saved 1.72 but running with 1.60")
        #expect(eye.recognisedByInstalledService == true)

        let align = try #require(values.first { $0.descriptor.id == "monado.floorAlign" })
        #expect(!align.isPendingReload)

        let refresh = try #require(values.first { $0.descriptor.id == "monado.refreshRate" })
        #expect(!refresh.isSet)
        #expect(refresh.effectiveValue == .integer(0))
        #expect(refresh.recognisedByInstalledService == false, "the fake binary does not mention this variable")
    }

    @Test func writesOnlyChangedVariablesAndBacksUp() throws {
        let home = try TemporaryDirectory()
        let agent = try makeMonadoInstall(in: home, environment: [
            "XRT_FLOOR_EYE_HEIGHT_M": "1.72", "PSVR2_TIMING_TRACE": "1", "SOME_OTHER_TUNING": "keep-me",
        ])
        let original = try Data(contentsOf: agent)
        let store = MonadoSettingsStore(agentURL: agent, backupDirectory: home.url.appending(path: "backups"))

        var changes: [String: SettingValue?] = [
            "monado.floorEyeHeight": .decimal(1.8),
            "monado.refreshRate": .integer(120),
        ]
        changes["monado.timingTrace"] = .some(nil)  // reset → remove the variable
        let backup = try store.write(changes)

        #expect(try Data(contentsOf: backup) == original, "backup is the untouched original")
        let written = try LaunchAgentDefinition.load(from: agent)
        #expect(written.environment == ["XRT_FLOOR_EYE_HEIGHT_M": "1.8", "XRT_MACOS_REFRESH_RATE_HZ": "120", "SOME_OTHER_TUNING": "keep-me"])
        // Everything outside EnvironmentVariables is preserved.
        #expect(written.label == MonadoInstallation.serviceLabel)
        #expect(written.machServices == [MonadoInstallation.machServiceName])
        #expect(written.raw["CustomUnknownKey"] == .dictionary(["nested": .integer(42)]))
        #expect(written.raw["RunAtLoad"] == .bool(false))
    }

    @Test func rejectsInvalidValuesWithoutWriting() throws {
        let home = try TemporaryDirectory()
        let agent = try makeMonadoInstall(in: home, environment: ["XRT_FLOOR_EYE_HEIGHT_M": "1.72"])
        let original = try Data(contentsOf: agent)
        let store = MonadoSettingsStore(agentURL: agent, backupDirectory: home.url.appending(path: "backups"))
        #expect(throws: SettingsError.self) {
            try store.write(["monado.floorEyeHeight": .decimal(9)])
        }
        #expect(try Data(contentsOf: agent) == original)
    }

    @Test func refusesWhenFileChangedSinceRead() throws {
        let home = try TemporaryDirectory()
        let agent = try makeMonadoInstall(in: home)
        let store = MonadoSettingsStore(agentURL: agent, backupDirectory: home.url.appending(path: "backups"))
        #expect(throws: SettingsError.agentChangedOnDisk) {
            try store.write(["monado.floorAlign": .bool(false)], expectedModificationDate: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func reportsMissingAgent() {
        let store = MonadoSettingsStore(agentURL: URL(fileURLWithPath: "/nonexistent/agent.plist"),
                                        backupDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(throws: SettingsError.self) { try store.read() }
    }
}

@Suite("App preferences")
struct AppPreferencesTests {
    func makeDefaults() -> UserDefaults {
        let name = "threshold-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func usesDefaultsUntilSet() throws {
        let prefs = AppPreferences(defaults: makeDefaults())
        #expect(prefs.automaticRuntimeQueries)
        #expect(prefs.refreshInterval == 3)
        #expect(prefs.workspaceRoot == "~/Code")

        let interval = SettingsCatalog.app.first { $0.id == AppPreferences.Key.refreshInterval }!
        try prefs.set(.integer(10), for: interval)
        #expect(prefs.refreshInterval == 10)
        #expect(throws: SettingsError.self) { try prefs.set(.integer(0), for: interval) }
        try prefs.set(nil, for: interval)
        #expect(prefs.refreshInterval == 3)
    }

    @Test func storesPathOverrides() {
        let prefs = AppPreferences(defaults: makeDefaults())
        prefs.setPathOverride("~/builds/kk.json", for: .kosmicKrisp)
        prefs.setPathOverride("   ", for: .xrizer)
        #expect(prefs.pathOverrides == ["kosmickrisp": "~/builds/kk.json"])
        prefs.setPathOverride(nil, for: .kosmicKrisp)
        #expect(prefs.pathOverrides.isEmpty)
    }

    @Test func monadoSettingsAreNotStoredInAppPreferences() {
        let prefs = AppPreferences(defaults: makeDefaults())
        #expect(throws: SettingsError.self) {
            try prefs.set(.bool(true), for: SettingsCatalog.monado[0])
        }
    }
}
