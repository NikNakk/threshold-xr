import AppKit
import SwiftUI
import ThresholdCore

struct WineSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addBridge = false
    @State private var advanced = false
    @State private var selectedRuntime: URL?
    private var setup: WineSetupController { model.wineSetup }
    private var build: SteamBridgeBuildController { model.steamBridgeBuild }
    private var busy: Bool { setup.isImporting || build.isRunning }

    init(addBridge: Bool = false) {
        _addBridge = State(initialValue: addBridge)
    }

    var body: some View {
        if advanced {
            SteamBridgeBuildView().environment(model)
        } else {
            setupContents
        }
    }

    private var setupContents: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up Wine").font(.title2.weight(.semibold))
            Text("Start with packaged Wine. Add the Steam bridge locally if you want to use native macOS Steam.")
                .foregroundStyle(.secondary)
            Text("This prepares the runtime. Steam Play registration and VR components are configured in the setup guide.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Choose a setup", selection: $addBridge) {
                Text("Packaged Wine").tag(false)
                Text("Wine + native Steam bridge").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(busy)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(addBridge ? "Build only the optional lsteamclient bridge on this Mac." : "No compiling: use Wine without lsteamclient.",
                          systemImage: addBridge ? "hammer" : "shippingbox")
                        .font(.headline)
                    Text(addBridge
                         ? "Compatible Windows games can use your macOS Steam client. Requires Apple Command Line Tools, Python 3, MinGW-w64 and Rosetta."
                         : "Use for Windows applications or a separate Windows Steam installation. Rosetta is required on Apple Silicon. Choose the bridge option for the current managed Steam Play tool.")
                        .font(.callout).foregroundStyle(.secondary)

                    if setup.installed == nil {
                        GroupBox("1. Get the matching package") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Open the successful GitHub build, download the “wine-bridge-sdk-prototype” artifact, then extract its ZIP in Finder. It contains Wine and the matching development bundle.")
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    if let release = setup.release {
                                        Text(release.title).foregroundStyle(.secondary)
                                        Spacer()
                                        Link("Open GitHub Downloads", destination: release.downloadURL)
                                    }
                                }
                            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        GroupBox("2. Prepare packaged Wine") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Choose the extracted folder containing the Wine .tar.xz and development-bundle .tar.gz. Threshold checks their identities and imports Wine into its own package folder.")
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button("Choose Download Folder…") { chooseFolder() }.disabled(busy)
                                    if let folder = setup.sourceFolder {
                                        Text(folder.lastPathComponent).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if setup.isImporting { ProgressView().controlSize(.small) }
                                    Button(setup.installed == nil ? "Prepare Wine" : "Package Ready") {
                                        Task { await setup.prepare() }
                                    }.disabled(busy || setup.sourceFolder == nil || setup.installed != nil || setup.release == nil)
                                }
                                if let message = setup.message {
                                    Text(message).font(.caption).foregroundStyle(setup.hasError ? .red : .secondary)
                                        .textSelection(.enabled)
                                }
                            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        }

                    } else if let kit = setup.installed {
                        GroupBox("1–2. Packaged Wine ready") {
                            HStack {
                                Label(kit.release.title, systemImage: "checkmark.circle.fill")
                                Spacer()
                                Button("Show Package") { NSWorkspace.shared.open(kit.directory) }
                            }.padding(6)
                        }
                    }

                    if addBridge {
                        GroupBox("3. Build the native Steam bridge") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("The matching Wine and development bundle are selected automatically. Only the bridge is compiled; a new runtime is created alongside packaged Wine.")
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    if build.isRunning { ProgressView().controlSize(.small) }
                                    Text(usingKitBuild ? build.status.phase.rawValue : "Ready to check setup").font(.headline)
                                    Spacer()
                                    if build.isRunning {
                                        Button("Cancel Build", role: .destructive) { build.cancel() }
                                    } else {
                                        Button("Check Setup") { startBridge(checkOnly: true) }
                                        Button("Build Steam Bridge") { startBridge(checkOnly: false) }
                                    }
                                }.disabled(setup.installed == nil || setup.isImporting)
                                if usingKitBuild, let message = build.status.message {
                                    Text(String(message.prefix(1000))).font(.caption)
                                        .foregroundStyle(build.status.phase == .failed ? .red : .secondary)
                                        .lineLimit(4).textSelection(.enabled)
                                }
                                if usingKitBuild, !build.status.logTail.isEmpty {
                                    DisclosureGroup("Build output") {
                                        ScrollView {
                                            Text(build.status.logTail).font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }.frame(height: 130)
                                    }
                                }
                                if usingKitBuild, let folder = build.status.directory {
                                    Button("Open Build Folder") { NSWorkspace.shared.open(folder) }
                                }
                            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let runtime = resultRuntime {
                        GroupBox(addBridge ? "4. Use Wine with the Steam bridge" : "3. Use packaged Wine") {
                            VStack(alignment: .leading, spacing: 10) {
                                PathText(path: runtime.path)
                                HStack {
                                    Button("Show Runtime") { NSWorkspace.shared.activateFileViewerSelecting([runtime]) }
                                    Button("Copy Runtime Path") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(runtime.path, forType: .string)
                                    }
                                    Button("Use for Wine Detection") {
                                        model.setOverride(runtime.path, for: .wine)
                                        selectedRuntime = runtime
                                    }
                                }
                                if selectedRuntime == runtime {
                                    Text("Components → Wine now uses this path.").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(addBridge
                                     ? "For VR games, supply this runtime to the Steam Play preparation tool with your DXMT, xrizer and OpenXR bridge."
                                     : "This is the Wine base. Install Windows Steam in a Wine prefix if using that route. The current managed Steam Play preparation tool requires the native Steam bridge.")
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                                Link("Open Steam Play Setup Guide", destination: URL(string: "https://github.com/NikNakk/macos-wine-xr/blob/codex/threshold-releases/docs/managed-stacks.md")!)
                                Text("Wine detection and Steam Play selection are separate settings. Existing game prefixes and your active Steam Play setup are preserved.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(.trailing, 8)
            }
            HStack {
                Button("Custom SDK Build…") { advanced = true }.disabled(busy)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 820, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(busy)
        .task { await setup.refresh() }
    }

    private var resultRuntime: URL? {
        guard let kit = setup.installed else { return nil }
        if !addBridge { return kit.runtime }
        return build.sourceRuntime == kit.runtime && build.status.phase == .complete ? build.status.runtime : nil
    }

    private var usingKitBuild: Bool {
        guard let kit = setup.installed else { return false }
        return build.sourceRuntime == kit.runtime
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose the folder extracted from the wine-bridge-sdk-prototype GitHub artifact."
        if panel.runModal() == .OK { setup.sourceFolder = panel.url }
    }

    private func startBridge(checkOnly: Bool) {
        guard let kit = setup.installed else { return }
        build.start(.init(sdk: .archive(kit.sdkArchive, sha256: kit.release.sdk.sha256), runtime: kit.runtime), checkOnly: checkOnly)
    }
}
