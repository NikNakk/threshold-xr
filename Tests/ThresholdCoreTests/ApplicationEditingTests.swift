import Foundation
import Testing
@testable import ThresholdCore

struct ApplicationEditingTests {
    @Test func manualSavePreservesOtherAppsAndDetectsExternalEdits() throws {
        let home = try TemporaryDirectory()
        let context = home.context()
        let initial = Data(#"[{"id":"a","title":"First","path":"/first"}]"#.utf8)
        let url = ShellAppCatalog.url(context: context)
        try ApplicationEditing.write(initial, to: url)
        let entry = Data(#"{"id":"b","title":" Second ","path":"/has spaces/run","arguments":["two words"],"environment":{"TEST":"a=b"}}"#.utf8)
        try ApplicationEditing.saveManual(entry, originalID: nil, original: initial, context: context)
        let entries = try ShellAppCatalog.load(context: context)
        #expect(entries.map(\.title) == ["First", "Second"])
        #expect(entries[1].arguments == ["two words"])
        #expect(throws: ApplicationEditingError.self) {
            try ApplicationEditing.saveManual(entry, originalID: "b", original: initial, context: context)
        }
        #expect(try ShellAppCatalog.load(context: context) == entries)
        let latest = try Data(contentsOf: url)
        #expect(throws: ShellAppCatalogError.self) {
            try ApplicationEditing.saveManual(entry, originalID: nil, original: latest, context: context)
        }
    }

    @Test func runtimeEditingPreservesGuestSpecificSettingsAndRejectsInvalidProfiles() throws {
        let home = try TemporaryDirectory()
        let json = #"{"schema":"threshold-runtime/app-profile-1","id":"test","title":"Original","guest":"android","components":{"host":"/host"},"android":{"pin":"/pin","apk":"/apk","app_root":"/tree","loader":"/loader"},"custom":{"keep":[1,2]},"parameters":{"scale":{"default":50}}}"#
        let url = try home.write("profiles/test.json", json)
        let data = Data(json.utf8)
        var object = try ApplicationEditing.validateProfile(data)
        object["title"] = "Edited"
        let edited = try JSONSerialization.data(withJSONObject: object)
        try ApplicationEditing.saveProfile(edited, to: url, original: data)
        let reloaded = try ApplicationEditing.validateProfile(Data(contentsOf: url))
        #expect(reloaded["title"] as? String == "Edited")
        #expect((reloaded["custom"] as? [String: [Int]])?["keep"] == [1, 2])
        object["android"] = [:]
        #expect(throws: ApplicationEditingError.self) { try ApplicationEditing.validateProfile(JSONSerialization.data(withJSONObject: object)) }
        #expect(throws: ApplicationEditingError.self) { try ApplicationEditing.saveProfile(data, to: url, original: data) }
    }

    private func importer(_ home: TemporaryDirectory, succeeds: Bool) throws -> DiscoveryContext {
        try home.write("runtime/android/tools/quest_import.py", """
        import argparse, pathlib, json, sys, shutil
        p = argparse.ArgumentParser()
        p.add_argument('--inspect', action='store_true')
        for name in ('apk', 'output', 'id', 'expected-sha256', 'components-json', 'game', 'content', 'portal-content'): p.add_argument('--' + name)
        a = p.parse_args()
        if a.inspect:
            print(json.dumps({'schema':'threshold-runtime/apk-inspection-1', 'title':'Imported app', 'package':'com.example.app',
                'version':'1', 'engine':'Unity', 'abis':['arm64-v8a'], 'activities':[], 'libraries':[], 'xr_apis':['OpenXR'],
                'meta_platform_sdk_present':False, 'adapter':'unity-openxr', 'sha256':'fixture', 'supported':True,
                'problems':[], 'warnings':[], 'games':[], 'dependencies':[{'name':'apktool','available':True}]}))
            sys.exit(0)
        out = pathlib.Path(a.output)
        out.mkdir()
        if \(succeeds ? "False" : "True"):
            print('Unsupported APK', file=sys.stderr)
            sys.exit(1)
        shutil.copyfile(a.apk, out / 'application.apk')
        (out / 'pin.json').write_text('{}')
        (out / 'app').mkdir()
        android = {name:str(out / value) for name,value in [('pin','pin.json'),('app_root','app'),('apk','application.apk')]}
        android['loader'] = '/loader'
        profile = {'schema':'threshold-runtime/app-profile-1','id':a.id,'title':'Imported app','guest':'android','components':{'host':'/host'},'android':android}
        (out / 'profile.json').write_text(json.dumps(profile))
        print(json.dumps({'schema':'threshold-runtime/apk-preparation-1', 'profile':str(out / 'profile.json'), 'sha256':a.expected_sha256}))
        """)
        try home.write("runtime/bin/threshold-run", "#!/bin/sh\necho '[]'\n", executable: true)
        try home.write("download with spaces.apk", "local APK bytes")
        return home.context(environment: ["THRESHOLD_RUNTIME": home.url.appending(path: "runtime").path,
                                          "THRESHOLD_PROFILES": home.url.appending(path: "profiles").path,
                                          "PATH": "/usr/bin:/bin"])
    }

    @Test func importPublishesCompleteProfileAndKeepsACopyOfTheAPK() throws {
        let home = try TemporaryDirectory()
        let context = try importer(home, succeeds: true)
        let source = home.url.appending(path: "download with spaces.apk")
        try ApplicationEditing.importAPK(source, context: context)
        let profiles = try FileManager.default.contentsOfDirectory(at: ApplicationEditing.profileDirectory(context: context), includingPropertiesForKeys: nil)
        #expect(profiles.count == 1)
        let profile = try ApplicationEditing.validateProfile(Data(contentsOf: profiles[0]))
        #expect(profile["title"] as? String == "Imported app")
        let android = try #require(profile["android"] as? [String: Any])
        let copy = URL(fileURLWithPath: try #require(android["apk"] as? String))
        #expect(copy != source)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: source))
        #expect(FileManager.default.fileExists(atPath: try #require(android["pin"] as? String)))
        #expect(FileManager.default.fileExists(atPath: try #require(android["app_root"] as? String)))
    }

    @Test func failedImportCleansStagedFilesAndPublishesNothing() throws {
        let home = try TemporaryDirectory()
        let context = try importer(home, succeeds: false)
        #expect(throws: ApplicationEditingError.self) {
            try ApplicationEditing.importAPK(home.url.appending(path: "download with spaces.apk"), context: context)
        }
        #expect(!FileManager.default.fileExists(atPath: ApplicationEditing.profileDirectory(context: context).path))
        let staged = context.home("Library/Application Support/ThresholdXR/QuestApps")
        #expect(try FileManager.default.contentsOfDirectory(atPath: staged.path).isEmpty)
    }
    @Test func runtimeOwnsInspectionAndUnsupportedAPKsCannotCreateProfiles() throws {
        let home = try TemporaryDirectory()
        let context = try importer(home, succeeds: true)
        let source = home.url.appending(path: "download with spaces.apk")
        var inspection = try QuestAPKImport.inspect(source, context: context)
        #expect(inspection.package == "com.example.app")
        #expect(inspection.xrApis == ["OpenXR"])
        inspection.supported = false
        inspection.problems = ["No adapter"]
        #expect(throws: ApplicationEditingError.self) {
            try QuestAPKImport.prepare(source, inspection: inspection, context: context)
        }
        #expect(!FileManager.default.fileExists(atPath: ApplicationEditing.profileDirectory(context: context).path))
    }

    @Test func sourceVRSelectionsArePassedToTheRuntime() throws {
        let home = try TemporaryDirectory()
        let context = try importer(home, succeeds: true)
        let tool = home.url.appending(path: "runtime/android/tools/quest_import.py")
        var script = try String(contentsOf: tool, encoding: .utf8)
        script = script.replacingOccurrences(of: "out = pathlib.Path(a.output)", with: """
        assert a.game == 'portal'
        assert pathlib.Path(a.content).name == 'Half Life content'
        assert pathlib.Path(a.portal_content).name == 'Portal content'
        out = pathlib.Path(a.output)
        """)
        try script.write(to: tool, atomically: true, encoding: .utf8)
        let source = home.url.appending(path: "download with spaces.apk")
        let inspection = try QuestAPKImport.inspect(source, context: context)
        try QuestAPKImport.prepare(source, inspection: inspection, game: "portal",
            content: home.url.appending(path: "Half Life content"), portalContent: home.url.appending(path: "Portal content"), context: context)
        #expect(try FileManager.default.contentsOfDirectory(atPath: ApplicationEditing.profileDirectory(context: context).path).count == 1)
    }

    @Test func inconsistentPreparationCannotPublishAProfile() throws {
        let home = try TemporaryDirectory()
        let context = try importer(home, succeeds: true)
        let tool = home.url.appending(path: "runtime/android/tools/quest_import.py")
        let script = try String(contentsOf: tool, encoding: .utf8)
            .replacingOccurrences(of: "'sha256':a.expected_sha256", with: "'sha256':'wrong'")
        try script.write(to: tool, atomically: true, encoding: .utf8)
        #expect(throws: ApplicationEditingError.self) {
            try ApplicationEditing.importAPK(home.url.appending(path: "download with spaces.apk"), context: context)
        }
        #expect(!FileManager.default.fileExists(atPath: ApplicationEditing.profileDirectory(context: context).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: context.home("Library/Application Support/ThresholdXR/QuestApps").path).isEmpty)
    }

}
