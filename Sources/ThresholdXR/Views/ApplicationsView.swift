import AppKit
import UniformTypeIdentifiers
import SwiftUI
import ThresholdCore

struct ApplicationsView: View {
    @Environment(AppModel.self) private var model
    @State private var editor: ApplicationEditorDraft?
    @State private var importSelection: QuestAPKSelection?
    @State private var importError: String?
    @State private var removal: RuntimeRemoval?

    private struct RuntimeRemoval {
        let target: LaunchTarget
        let profile: FrameworkProfile
        let data: Data

        var details: String {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let android = object?["android"] as? [String: Any]
            let expansion = android?["obb"] == nil ? "" : "\nIncludes an OBB expansion."
            return "\(profile.id)\(expansion)\n\nThe launch profile will move to Trash. Game files stay on disk."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Start an application straight into the headset. If Threshold Home is running, it hands the headset over and takes it back when the app ends. Launched apps keep running if you quit Threshold XR.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Import Quest APK…", systemImage: "square.and.arrow.down") { importAPK() }
                    Button("Add Application…", systemImage: "plus") { editManual() }
                }
                Text("Import a Quest APK to inspect its engine and preparation requirements. Runtime and manual apps can be edited here; manage Steam applications in Steam.")
                    .font(.callout).foregroundStyle(.secondary)
                catalog
                history

                Text("Any OpenXR application can also be started from Finder, the Dock or a terminal; it finds Monado through the system OpenXR registration without Threshold XR running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .sheet(item: $importSelection) { selection in QuestAPKImportView(apk: selection.url).environment(model) }
        .sheet(item: $editor) { draft in ApplicationEditorView(draft: draft).environment(model) }
        .alert("Application settings", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
        .confirmationDialog(
            removal.map { "Remove \($0.target.title)?" } ?? "Remove application?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible, presenting: removal
        ) { selected in
            Button("Remove Profile", role: .destructive) { removeRuntime(selected) }
        } message: { selected in
            Text(selected.details)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.discoverComponents() }
                } label: {
                    Label("Reload Catalog", systemImage: "arrow.clockwise")
                }
                .help("Read Threshold Home's application catalog again")
            }
        }
    }

    private func editManual(_ id: String? = nil) {
        do { editor = try .manual(context: model.context, id: id) }
        catch { importError = error.localizedDescription }
    }

    private func editRuntime(_ target: LaunchTarget) {
        let context = model.context
        Task {
            do {
                let profiles = try await Task.detached { try FrameworkCatalog.load(context: context) }.value
                guard let profile = profiles.first(where: { $0.id == target.frameworkProfileID }) else {
                    throw ApplicationEditingError.invalid("This profile is no longer available. Reload the list.")
                }
                let url = URL(fileURLWithPath: profile.path)
                let data = try Data(contentsOf: url)
                editor = ApplicationEditorDraft(source: .framework, url: url, original: data, originalID: profile.id, json: data)
            } catch { importError = error.localizedDescription }
        }
    }

    private func confirmRemoval(_ target: LaunchTarget) {
        let context = model.context
        Task {
            do {
                removal = try await Task.detached {
                    let profiles = try FrameworkCatalog.load(context: context)
                    guard let profile = profiles.first(where: { $0.id == target.frameworkProfileID }) else {
                        throw ApplicationEditingError.invalid("This profile is no longer available. Reload the list.")
                    }
                    let data = try Data(contentsOf: URL(fileURLWithPath: profile.path))
                    return RuntimeRemoval(target: target, profile: profile, data: data)
                }.value
            } catch { importError = error.localizedDescription }
        }
    }

    private func removeRuntime(_ selected: RuntimeRemoval) {
        guard model.launches.activeRecord(for: selected.target.id) == nil else {
            importError = "Stop this application before removing its profile."
            return
        }
        do {
            try ApplicationEditing.removeProfile(at: URL(fileURLWithPath: selected.profile.path),
                                                 id: selected.profile.id, original: selected.data, context: model.context)
            Task { await model.discoverComponents() }
        } catch { importError = error.localizedDescription }
    }

    private func importAPK() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.message = "Select a downloaded Quest APK to inspect it and choose preparation options."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSelection = QuestAPKSelection(url: url)
    }

    // MARK: Catalog

    @ViewBuilder
    private func section(_ source: ApplicationCatalog.Source) -> some View {
        let targets = model.applications.targets(from: source)
        Text(source.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, source == .shellCatalog ? 4 : 16)
            .padding(.bottom, 4)
        if let error = model.applications.problem(source) {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .padding(8)
        } else if targets.isEmpty {
            Text(emptyText(source))
                .foregroundStyle(.secondary)
                .padding(8)
        }
        ForEach(targets) { target in
            Divider()
            ApplicationRow(target: target, duplicateTitle: source == .framework && targets.filter { $0.title == target.title }.count > 1, edit: {
                if source == .shellCatalog { editManual(target.id) }
                else { editRuntime(target) }
            }, remove: source == .framework ? { confirmRemoval(target) } : nil)
        }
    }

    private func emptyText(_ source: ApplicationCatalog.Source) -> String {
        switch source {
        case .shellCatalog: return "No manually configured applications. Choose Add Application to create one."
        case .framework: return "threshold-runtime provides no applications."
        case .steam: return "Steam has no VR games installed."
        }
    }

    private var catalog: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                ForEach([ApplicationCatalog.Source.shellCatalog, .framework, .steam], id: \.self) { source in
                    section(source)
                }
            }
        } label: {
            HStack {
                Text("Applications").font(.headline)
                Spacer()
                Button("Reveal Catalog File") { model.reveal(ShellAppCatalog.url(context: model.context).path) }
                    .buttonStyle(.link)
                    .help("Threshold Home's apps.json, shared by Threshold XR and Threshold Home")
            }
        }
    }

    // MARK: History

    @ViewBuilder
    private var history: some View {
        let records = model.launches.records.reversed()
        if !records.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(records.prefix(20))) { record in
                        LaunchHistoryRow(record: record)
                        if record.id != records.prefix(20).last?.id { Divider() }
                    }
                }
            } label: {
                Text("Recent launches").font(.headline)
            }
        }
    }
}

private struct ApplicationRow: View {
    @Environment(AppModel.self) private var model
    let target: LaunchTarget
    let duplicateTitle: Bool
    var edit: () -> Void
    var remove: (() -> Void)?

    var body: some View {
        let active = model.launches.activeRecord(for: target.id)
        let latest = model.launches.latestRecord(for: target.id)
        let issues = model.launches.preflight(target, monado: model.monado)
            .filter { !(active != nil && $0.message.contains("already running")) }

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: target.systemImage ?? (target.kind == .appBundle ? "app" : "terminal"))
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(target.title).font(.headline)
                        if let record = active ?? latest {
                            StatusPill(text: record.phase.title, tone: record.phase.tone)
                        }
                    }
                    if let subtitle = target.subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    if duplicateTitle, let id = target.frameworkProfileID {
                        Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let folder = target.steamInstallFolder {
                        // The target's URL is steam://..., not a file: show where Steam installed it.
                        PathText(path: folder.path, exists: FileManager.default.fileExists(atPath: folder.path))
                        if let appID = target.steamAppID {
                            Text("Steam app \(String(appID)) · \(target.url.absoluteString)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    } else {
                        PathText(path: target.url.path, exists: FileManager.default.fileExists(atPath: target.url.path))
                    }
                    if !target.arguments.isEmpty {
                        Text("Arguments: \(target.arguments.joined(separator: " "))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                controls(active: active, latest: latest, issues: issues)
            }
            if let problem = (active ?? latest)?.monadoProblem {
                Label {
                    Text("While this app ran, Monado reported: \(problem)").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .padding(.leading, 44)
            }
            ForEach(issues, id: \.self) { issue in
                Label {
                    Text(issue.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: issue.severity.icon).foregroundStyle(issue.severity.color)
                }
                .padding(.leading, 44)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func controls(active: LaunchRecord?, latest: LaunchRecord?, issues: [LaunchIssue]) -> some View {
        HStack(spacing: 8) {
            if target.source != .steam {
                Button("Edit…", action: edit).disabled(active != nil)
                if let remove {
                    Button("Remove…", action: remove).disabled(active != nil)
                }
            } else {
                Button("Manage in Steam") {
                    if let id = target.steamAppID, let url = URL(string: "steam://nav/games/details/\(id)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if let log = (active ?? latest)?.logURL {
                Button("Log") { model.open(log.path) }
                    .help("Open this launch's output log")
            }
            if let active {
                Button(role: .destructive) {
                    model.stopLaunch(active)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(active.phase == .stopping)
                .help("Ask the app to quit; it is forced to quit after a few seconds")
            } else {
                Button {
                    model.launch(target)
                } label: {
                    Label("Launch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!LaunchPreflight.canLaunch(issues))
            }
        }
    }
}

private struct LaunchHistoryRow: View {
    @Environment(AppModel.self) private var model
    let record: LaunchRecord

    var body: some View {
        HStack(spacing: 10) {
            StatusPill(text: record.phase.title, tone: record.phase.tone)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let report = record.crashReport {
                Button("Crash Report") { model.open(report.path) }.buttonStyle(.link)
            }
            if let log = record.logURL {
                Button("Log") { model.open(log.path) }.buttonStyle(.link)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private var detail: String {
        var parts = ["Started \(record.startedAt.formatted(date: .omitted, time: .standard))"]
        if let pid = record.pid { parts.append("pid \(pid)") }
        if let duration = record.duration {
            parts.append("ran \(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))")
        }
        if let exit = record.exit { parts.append(exit.description) }
        if case let .failed(message) = record.phase { parts.append(message) }
        if let client = record.clientName { parts.append("Monado client \"\(client)\"") }
        if let problem = record.monadoProblem { parts.append("Monado: \(problem)") }
        return parts.joined(separator: " · ")
    }
}

extension LaunchRecord.Phase {
    var title: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .connected: "Connected"
        case .presenting: "In headset"
        case .stopping: "Stopping"
        case .exited: "Ended"
        case .crashed: "Crashed"
        case .failed: "Failed"
        }
    }

    var tone: Tone {
        switch self {
        case .starting, .stopping: .caution
        case .running: .neutral
        case .connected, .presenting: .good
        case .exited: .inactive
        case .crashed, .failed: .bad
        }
    }
}

extension LaunchIssue.Severity {
    var icon: String {
        switch self {
        case .blocking: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .blocking: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}
