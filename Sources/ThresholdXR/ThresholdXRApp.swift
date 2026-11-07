import AppKit
import SwiftUI

@main
struct ThresholdXRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Threshold XR", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    model.start()
                    if let directory = DebugSnapshot.outputDirectory {
                        await DebugSnapshot.run(model: model, to: directory)
                    }
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task {
                        await model.refreshStatus()
                        await model.discoverComponents()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

/// Quitting Threshold XR deliberately does nothing to Monado: the runtime is
/// owned by launchd and keeps serving applications after the app exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Built as a plain SwiftPM executable during development, the process
        // would otherwise start as a background app without a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
