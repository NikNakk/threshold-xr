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
