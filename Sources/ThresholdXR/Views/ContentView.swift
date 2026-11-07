import SwiftUI
import ThresholdCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case home, applications, components, headset, settings, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .applications: "Applications"
        case .components: "Components"
        case .headset: "Headset"
        case .settings: "Settings"
        case .diagnostics: "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .applications: "square.grid.2x2"
        case .components: "shippingbox"
        case .headset: "visionpro"
        case .settings: "gearshape"
        case .diagnostics: "stethoscope"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("sidebarSelection") private var selection: SidebarItem = .home

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarItem.allCases, selection: Binding($selection)) { item in
                Label(item.title, systemImage: item.systemImage)
                    .badge(badge(for: item))
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch selection {
                case .home: HomeView(selection: $selection)
                case .applications: ApplicationsView()
                case .components: ComponentsView()
                case .headset: HeadsetView()
                case .settings: SettingsView()
                case .diagnostics: DiagnosticsView()
                }
            }
            .navigationTitle(selection.title)
        }
        .alert(item: $model.error) { error in
            Alert(
                title: Text(error.title),
                message: Text([error.message, error.suggestion].compactMap { $0 }.joined(separator: "\n\n")),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .settings: return model.monado?.pendingEnvironmentChanges.isEmpty == false ? 1 : 0
        default: return 0
        }
    }
}
