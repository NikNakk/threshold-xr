import AppKit
import SwiftUI
import ThresholdCore

struct QuestAPKSelection: Identifiable {
    let id = UUID()
    let url: URL
}

struct QuestAPKImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let apk: URL
    @State private var inspection: QuestAPKInspection?
    @State private var inspecting = false
    @State private var preparing = false
    @State private var error: String?
    @State private var game = "hl2"
    @State private var content: URL?
    @State private var portalContent: URL?

    private var selectedGame: QuestAPKInspection.Game? { inspection?.games.first { $0.id == game } }
    private var needsPortal: Bool { selectedGame?.contentFolders.contains("portal") == true }
    private var missingContent: [String] {
        (selectedGame?.contentFolders ?? []).filter { name in
            let root = name == "portal" ? portalContent : content
            guard let root else { return true }
            var directory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: root.appending(path: name).path, isDirectory: &directory) || !directory.boolValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Quest APK").font(.title2.bold())
            Text(apk.lastPathComponent).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if inspecting { ProgressView("Inspecting APK…") }
                    if let inspection {
                        GroupBox("APK details") {
                            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                                detail("Application", inspection.title)
                                detail("Package", inspection.package)
                                detail("Version", inspection.version)
                                detail("Engine", inspection.engine)
                                detail("Architectures", inspection.abis.joined(separator: ", "))
                                detail("XR APIs", inspection.xrApis.joined(separator: ", "))
                                detail("Preparation", inspection.adapter ?? "Unavailable")
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        ForEach(inspection.problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        if !inspection.games.isEmpty {
                            GroupBox("Game content") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Picker("Game", selection: $game) {
                                        ForEach(inspection.games) { game in Text(game.title).tag(game.id) }
                                    }
                                    Text("Choose your installed retail game folders. The importer links to these files; keep the folders available after import.")
                                        .font(.callout).foregroundStyle(.secondary)
                                    folder("Half-Life 2 folder", selection: $content)
                                    if needsPortal { folder("Portal folder", selection: $portalContent) }
                                    if let selectedGame {
                                        Text("Required subfolders: \(selectedGame.contentFolders.joined(separator: ", "))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !missingContent.isEmpty {
                                        Text("Missing: \(missingContent.joined(separator: ", "))").font(.callout).foregroundStyle(.orange)
                                    }
                                }.padding(8)
                            }
                        }
                        if inspection.dependencies.contains(where: { !$0.available }) {
                            GroupBox("Preparation tools required") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Install apktool in Terminal, then check again:")
                                    Text("brew install apktool").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    Link("Homebrew installation instructions", destination: URL(string: "https://brew.sh")!)
                                    Button("Check Again") { Task { await inspect() } }.disabled(preparing)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                        }
                        DisclosureGroup("Technical details") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("SHA-256: \(inspection.sha256)")
                                Text("Activities: \(inspection.activities.joined(separator: ", "))")
                                Text("Meta Platform SDK: \(inspection.metaPlatformSdkPresent ? "Detected" : "Not detected")")
                                Text(inspection.libraries.joined(separator: "\n"))
                            }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        ForEach(inspection.warnings, id: \.self) { warning in
                            Text(warning).font(.callout).foregroundStyle(.secondary)
                        }
                        Text("Threshold XR keeps a copy of the APK and adds the prepared app to the shared applications list.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        if inspection == nil {
                            Text("Inspection requires Python 3 and a current threshold-runtime checkout.").font(.callout).foregroundStyle(.secondary)
                            Button("Try Again") { Task { await inspect() } }.disabled(inspecting)
                        }
                    }
                }.padding(2)
            }
            HStack {
                if preparing { ProgressView().controlSize(.small); Text("Preparing app and creating profile…") }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(preparing)
                Button("Import") { prepare() }.keyboardShortcut(.defaultAction)
                    .disabled(inspecting || preparing || inspection?.supported != true || !missingContent.isEmpty || inspection?.dependencies.contains(where: { !$0.available }) == true)
            }
        }
        .padding(24).frame(width: 700, height: 650)
        .interactiveDismissDisabled(preparing)
        .task { await inspect() }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value.isEmpty ? "Unknown" : value).textSelection(.enabled) }
    }

    private func folder(_ label: String, selection: Binding<URL?>) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(label)
                Text(selection.wrappedValue?.path ?? "No folder selected").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.message = label
                if panel.runModal() == .OK { selection.wrappedValue = panel.url }
            }.disabled(preparing)
        }
    }

    private func inspect() async {
        inspecting = true
        error = nil
        inspection = nil
        defer { inspecting = false }
        let context = model.context
        do {
            inspection = try await Task.detached(priority: .userInitiated) { try QuestAPKImport.inspect(apk, context: context) }.value
        } catch { self.error = error.localizedDescription }
    }

    private func prepare() {
        guard let inspection else { return }
        preparing = true
        error = nil
        let context = model.context
        let game = selectedGame?.id, content = content, portalContent = portalContent
        Task {
            defer { preparing = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try QuestAPKImport.prepare(apk, inspection: inspection, game: game, content: content, portalContent: portalContent, context: context)
                }.value
                await model.discoverComponents()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
