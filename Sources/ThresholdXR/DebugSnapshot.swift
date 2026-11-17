import AppKit
import SwiftUI

/// Developer aid: `threshold-xr --snapshot <dir> [--appearance dark|light]`
/// renders each screen to PNG from inside the app's own process (no Screen
/// Recording permission needed), then quits. Used for documentation and for
/// checking layouts without a display session.
@MainActor
enum DebugSnapshot {
    static var outputDirectory: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1])
    }

    static var appearanceName: NSAppearance.Name {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--appearance"), index + 1 < args.count, args[index + 1] == "dark" {
            return .darkAqua
        }
        return .aqua
    }

    static func run(model: AppModel, to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Wait for status and component discovery.
        for _ in 0..<100 where model.monado == nil || model.components.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let suffix = appearanceName == .darkAqua ? "-dark" : ""
        if CommandLine.arguments.contains("--snapshot-github-builds") {
            await model.buildCatalogue.refresh(installer: model.releaseInstaller)
            let host = NSHostingView(rootView: GitHubBuildsView().environment(model))
            host.frame = NSRect(x: 0, y: 0, width: 740, height: 660)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = host
            window.orderBack(nil)
            window.alphaValue = 0.01
            try? await Task.sleep(for: .milliseconds(700))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: directory.appending(path: "github-builds\(suffix).png"))
                }
            }
            window.orderOut(nil)
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--snapshot-steam-bridge") || CommandLine.arguments.contains("--snapshot-wine-setup") || CommandLine.arguments.contains("--snapshot-wine-setup-bridge") {
            let bridge = CommandLine.arguments.contains("--snapshot-wine-setup-bridge")
            let guided = CommandLine.arguments.contains("--snapshot-wine-setup") || bridge
            if guided, let index = CommandLine.arguments.firstIndex(of: "--wine-kit-folder"), index + 1 < CommandLine.arguments.count {
                model.wineSetup = WineSetupController(root: directory.appending(path: "packages"))
                model.wineSetup.sourceFolder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                await model.wineSetup.prepare()
            }
            let root = guided ? AnyView(WineSetupView(addBridge: bridge).environment(model)) : AnyView(SteamBridgeBuildView().environment(model))
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: guided ? 820 : 780, height: 760)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = host
            window.orderBack(nil)
            window.alphaValue = 0.01
            try? await Task.sleep(for: .milliseconds(700))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    let name = bridge ? "wine-setup-bridge" : (guided ? "wine-setup" : "steam-bridge")
                    try? data.write(to: directory.appending(path: "\(name)\(suffix).png"))
                }
            }
            window.orderOut(nil)
            NSApp.terminate(nil)
            return
        }
        for item in SidebarItem.allCases {
            let root = SnapshotRoot(item: item).environment(model)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 1120, height: 780)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = host
            window.orderBack(nil)
            window.alphaValue = 0.01
            try? await Task.sleep(for: .milliseconds(700))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appending(path: "\(item.rawValue)\(suffix).png"))
            }
            window.orderOut(nil)
        }
        NSApp.terminate(nil)
    }
}

private struct SnapshotRoot: View {
    let item: SidebarItem
    @State private var selection: SidebarItem

    init(item: SidebarItem) {
        self.item = item
        _selection = State(initialValue: item)
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: Binding($selection)) { item in
                Label(item.title, systemImage: item.systemImage).tag(item)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            switch item {
            case .home: HomeView(selection: $selection)
            case .applications: ApplicationsView()
            case .components: ComponentsView()
            case .headset: HeadsetView()
            case .settings: SettingsView()
            case .diagnostics: DiagnosticsView()
            }
        }
    }
}
