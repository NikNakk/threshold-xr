import AppKit
import SwiftUI
import ThresholdCore

struct SteamBridgeBuildView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sdkKind = SDKKind.archive
    @State private var sdkPath = ""
    @State private var checksum = ""
    @State private var runtimePath = ""
    @State private var jobs = min(ProcessInfo.processInfo.activeProcessorCount, 6)

    private enum SDKKind: String, CaseIterable {
        case archive = "Archive", folder = "Folder", download = "Download"
    }
    private var build: SteamBridgeBuildController { model.steamBridgeBuild }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Build Steam Bridge").font(.title2.weight(.semibold))
            Text("Compile the Steam bridge on this Mac and create a separate Wine runtime.")
                .foregroundStyle(.secondary)
            Form {
                Section("Development bundle") {
                    Picker("Source", selection: $sdkKind) {
                        ForEach(SDKKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField(sdkKind == .download ? "HTTPS archive URL" : "Bundle path", text: $sdkPath)
                            .textFieldStyle(.roundedBorder)
                        if sdkKind != .download {
                            Button("Choose…") { chooseSDK() }
                        }
                    }
                    if sdkKind != .folder {
                        TextField("SHA-256", text: $checksum)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                    }
                    Text("Use the development bundle paired with your Wine runtime. Downloads and archives are checked against the checksum before extraction.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Wine runtime") {
                    HStack {
                        TextField("Runtime folder", text: $runtimePath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            chooseDirectory("Choose the Wine runtime paired with the development bundle.") { runtimePath = $0.path }
                        }
                    }
                    Stepper("Parallel build jobs: \(jobs)", value: $jobs, in: 1...16)
                }
            }
            .formStyle(.grouped)
            .disabled(build.isRunning)
            .frame(height: 360)

            Text("Requires Apple Command Line Tools, Python 3, MinGW-w64 and Rosetta. Check Setup reports any missing tools and how to install them.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                if build.isRunning { ProgressView().controlSize(.small) }
                Text(build.status.phase.rawValue).font(.headline)
                Spacer()
                if let directory = build.status.directory {
                    Button("Open Build Folder") { NSWorkspace.shared.open(directory) }
                }
            }
            if let message = build.status.message {
                Text(String(message.prefix(1400)))
                    .font(.caption)
                    .foregroundStyle(build.status.phase == .failed ? .red : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(build.status.logTail.isEmpty ? "Compiler progress and build errors will appear here." : build.status.logTail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: build.status.logTail) { reader.scrollTo("end", anchor: .bottom) }
            }
            .padding(8)
            .frame(minHeight: 80, maxHeight: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            if let runtime = build.status.runtime {
                HStack {
                    PathText(path: runtime.path)
                    Spacer()
                    Button("Show Runtime") { NSWorkspace.shared.activateFileViewerSelecting([runtime]) }
                }
            }
            Text("Build outputs stay in a new folder. Your selected runtime, game prefixes and active Steam Play configuration are unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(build.isRunning)
                Spacer()
                if build.isRunning {
                    Button("Cancel Build", role: .destructive) { build.cancel() }
                        .disabled(build.status.phase == .cancelling)
                } else {
                    Button("Check Setup") { start(checkOnly: true) }
                        .disabled(request == nil)
                    Button("Build Local Runtime") { start(checkOnly: false) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(request == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 780, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(build.isRunning)
        .onAppear {
            if runtimePath.isEmpty { runtimePath = model.components.first(where: { $0.id == .wine })?.location ?? "" }
        }
    }

    private var request: SteamBridgeBuildRequest? {
        let path = sdkPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtime = runtimePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, runtime.hasPrefix("/") else { return nil }
        let source: SteamBridgeBuildRequest.SDK
        let hash = checksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch sdkKind {
        case .folder:
            guard path.hasPrefix("/") else { return nil }
            source = .directory(URL(fileURLWithPath: path))
        case .archive:
            guard path.hasPrefix("/") else { return nil }
            source = .archive(URL(fileURLWithPath: path), sha256: hash)
        case .download:
            guard let url = URL(string: path) else { return nil }
            source = .download(url, sha256: hash)
        }
        let request = SteamBridgeBuildRequest(sdk: source, runtime: URL(fileURLWithPath: runtime), jobs: jobs)
        return (try? request.validate()) == nil ? nil : request
    }

    private func start(checkOnly: Bool) {
        if let request { build.start(request, checkOnly: checkOnly) }
    }

    private func chooseSDK() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = sdkKind == .archive
        panel.canChooseDirectories = sdkKind == .folder
        panel.message = "Choose a Wine development bundle folder or its tar.gz archive."
        if panel.runModal() == .OK, let url = panel.url { sdkPath = url.path }
    }

    private func chooseDirectory(_ message: String, selected: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url { selected(url) }
    }
}
