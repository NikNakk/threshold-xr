import SwiftUI
import ThresholdCore
import UniformTypeIdentifiers

struct ComponentsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ComponentID? = .monado
    @State private var showGitHubBuilds = false
    @State private var showSteamBridgeBuild = false

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            HSplitView {
                List(model.components, selection: $selection) { component in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(component.id.displayName).font(.headline)
                            Text(component.id.role.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusPill(text: component.state.rawValue, tone: component.state.tone)
                    }
                    .padding(.vertical, 3)
                    .tag(component.id)
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                .overlay {
                    if model.components.isEmpty && model.isDiscoveringComponents {
                        ProgressView("Detecting components…")
                    }
                }

                Group {
                    if let id = selection, let component = model.components.first(where: { $0.id == id }) {
                        ComponentDetail(component: component)
                            .id(component.id)
                    } else {
                        Text("Select a component").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showGitHubBuilds) { GitHubBuildsView().environment(model) }
        .sheet(isPresented: $showSteamBridgeBuild) { WineSetupView().environment(model) }
        .task { await model.refreshReleaseStacks() }
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { primaryActions; secondaryActions }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { primaryActions }.fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 8) { secondaryActions }.fixedSize(horizontal: true, vertical: false)
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var primaryActions: some View {
        Button(model.buildCatalogue.updateCount > 0 ? "GitHub Builds (\(model.buildCatalogue.updateCount))…" : "GitHub Builds…",
               systemImage: "arrow.down.circle") { showGitHubBuilds = true }
            .help("Find new dependency builds on GitHub and install or update them.")
        Button("Set Up Wine…", systemImage: "shippingbox") { showSteamBridgeBuild = true }
            .help("Use Windows Steam by default, or explicitly prepare the private native Steam integration.")
        Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.message = "Choose a pinned Threshold XR release stack from a trusted source."
            if panel.runModal() == .OK, let url = panel.url {
                Task { await model.installReleaseStack(url) }
            }
        } label: {
            if model.isInstallingRelease {
                HStack { ProgressView().controlSize(.small); Text("Installing Stack…") }
            } else { Label("Install Stack…", systemImage: "doc.text") }
        }
        .disabled(model.isInstallingRelease || model.buildCatalogue.installing != nil)
        .help("Install a pinned set of dependencies from a release-stack JSON file.")
    }

    @ViewBuilder private var secondaryActions: some View {
        Menu("Launch Stack", systemImage: "square.stack.3d.up") {
            Button("Select Windows XR Profile…", systemImage: "person.crop.rectangle") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.json]
                panel.message = "Choose a prepared Windows Steam or private native Steam launch-stack profile."
                if panel.runModal() == .OK, let url = panel.url {
                    Task { await model.selectWindowsXRProfile(url) }
                }
            }
            Divider()
            ForEach(model.installedReleaseStacks) { installed in
                Button(installed.id) { Task { await model.selectLaunchStack(installed) } }
            }
            Divider()
            Button("Use Profile Dependencies") { Task { await model.clearLaunchStack() } }
        }
        .disabled(model.isInstallingRelease || model.buildCatalogue.installing != nil)
        .fixedSize()
        .help("Select client dependencies for Threshold Runtime; this does not switch the Monado service.")
        Button("Installed Releases", systemImage: "folder") {
            NSWorkspace.shared.open(ReleaseInstaller.defaultRoot())
        }
        .disabled(model.buildCatalogue.installed.isEmpty)
        .help("Open the folder containing installed dependency releases.")
        Button {
            Task { await model.discoverComponents() }
        } label: {
            if model.isDiscoveringComponents {
                HStack { ProgressView().controlSize(.small); Text("Detecting…") }
            } else { Label("Detect Again", systemImage: "arrow.clockwise") }
        }
        .help("Scan local paths again to detect installed components.")
        .disabled(model.isDiscoveringComponents)
    }
}

private struct ComponentDetail: View {
    @Environment(AppModel.self) private var model
    let component: ComponentStatus
    @State private var overrideText = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { StatusPill(text: component.state.rawValue, tone: component.state.tone) }
                LabeledContent("Role", value: component.id.role.rawValue)
                LabeledContent("Version", value: component.version ?? "Unknown")
                LabeledContent("Location") {
                    if let location = component.location { PathText(path: location) } else { Text("—").foregroundStyle(.secondary) }
                }
                if let source = component.source {
                    LabeledContent("Source checkout") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(source.summary).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            PathText(path: source.root.path)
                        }
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(component.id.displayName).font(.title2.weight(.semibold))
                    Text(component.id.summary).foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }

            if !component.notes.isEmpty {
                Section("Notes") {
                    ForEach(component.notes, id: \.self) { note in
                        Label {
                            Text(note.text).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: note.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                                .foregroundStyle(note.severity == .warning ? .orange : .secondary)
                        }
                    }
                }
            }

            Section("Detected files") {
                if component.artifacts.isEmpty {
                    Text("Nothing was found in the locations checked.").foregroundStyle(.secondary)
                }
                ForEach(component.artifacts) { artifact in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: artifact.exists ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(artifact.exists ? .green : .red)
                            Text(artifact.role).font(.callout.weight(.medium))
                            Spacer()
                            if let version = artifact.version {
                                Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(artifact.source.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("How this location was found")
                        }
                        PathText(path: artifact.path, exists: artifact.exists)
                        if let detail = artifact.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                HStack {
                    TextField(component.id.overrideHint, text: $overrideText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(applyOverride)
                    Button("Choose…", action: choosePath)
                }
                HStack {
                    Button("Apply", action: applyOverride)
                        .disabled(overrideText == currentOverride)
                    Button("Clear Override") {
                        overrideText = ""
                        model.setOverride(nil, for: component.id)
                    }
                    .disabled(currentOverride.isEmpty)
                }
            } header: {
                Text("Detection path")
            } footer: {
                Text("An override is checked before any other location. Leave it empty to use automatic detection. Threshold XR only reads these locations.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { overrideText = currentOverride }
    }

    private var currentOverride: String {
        model.preferences.pathOverrides[component.id.rawValue] ?? ""
    }

    private func applyOverride() {
        let trimmed = overrideText.trimmingCharacters(in: .whitespaces)
        model.setOverride(trimmed.isEmpty ? nil : trimmed, for: component.id)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the location of \(component.id.displayName): \(component.id.overrideHint)"
        if panel.runModal() == .OK, let url = panel.url {
            overrideText = url.path
            applyOverride()
        }
    }
}
