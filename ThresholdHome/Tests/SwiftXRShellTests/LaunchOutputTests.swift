import Foundation
import Testing
import ThresholdCore
@testable import SwiftXRShell

struct LaunchOutputTests {
    @Test func failureDetailsRemainBoundedAndVisible() {
        let tail = LaunchOutputTail()
        tail.append(Data(repeating: 65, count: 100_000))
        tail.append(Data("\nAssetto Corsa: 32-bit ntdll.dll is unavailable\n".utf8))
        #expect(tail.summary.utf8.count <= 16_384)
        #expect(tail.summary.contains("32-bit ntdll.dll"))
        let error = ExternalOpenXRLauncherError.executableFailed(title: "Assetto Corsa", status: 1, detail: tail.summary)
        #expect(error.localizedDescription.contains("32-bit ntdll.dll"))
    }
}

struct SharedCatalogTests {
    @Test func frameworkApplicationsKeepHomeUpAndStopPatiently() throws {
        let json = #"{"id": "alyx", "title": "Half-Life: Alyx", "guest": "linux", "path": "/p/alyx.json", "openxr_application_name": "alyx_host"}"#
        let profile = try JSONDecoder().decode(FrameworkProfile.self, from: Data(json.utf8))
        let application = ShellApplication(target: LaunchTarget(profile: profile, runner: URL(fileURLWithPath: "/rt/bin/threshold-run")))
        #expect(application.id == "threshold-runtime.alyx")
        guard case let .external(external) = application.kind else {
            Issue.record("expected an external application")
            return
        }
        #expect(external.arguments == ["alyx"])
        #expect(external.openXRApplicationName == "alyx_host")
        #expect(external.openXRClientTimeout == 120)
        #expect(external.stopGracePeriod == 10)
        #expect(external.showsHomeWhileStarting)
    }

    @Test func catalogEntriesKeepHomeDefaults() {
        let target = LaunchTarget(id: "paint", title: "Paint", url: URL(fileURLWithPath: "/Applications/Paint.app"))
        let application = ShellApplication(target: target)
        guard case let .external(external) = application.kind else {
            Issue.record("expected an external application")
            return
        }
        #expect(application.subtitle == "OpenXR application")
        #expect(external.openXRClientTimeout == 30)
        #expect(external.stopGracePeriod == 2)
        #expect(!external.showsHomeWhileStarting)
    }

    @Test func logSummarySkipsTheLaunchHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-log-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("# Threshold XR launch of X\n# env A=1\nloading\nerror: no host\n".utf8).write(to: url)
        let summary = LaunchOutputTail.summary(ofLogAt: url)
        #expect(summary == "loading\nerror: no host")
    }
}
