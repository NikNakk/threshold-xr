import SwiftUI
import ThresholdCore

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.serviceLog
    @State private var logText = ""
    @State private var logFile: URL?

    enum Tab: String, CaseIterable, Identifiable {
        case serviceLog = "Service Log"
        case activity = "Activity"
        case environment = "Environment"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            switch tab {
            case .serviceLog: serviceLog
            case .activity: activityLog
            case .environment: environment
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DiagnosticReport.make(model: model), forType: .string)
                    model.record(.info, "Copied a diagnostic report to the clipboard.")
                } label: {
                    Label("Copy Report", systemImage: "doc.on.clipboard")
                }
                .help("Copy a plain-text diagnostic report")
            }
        }
    }

    // MARK: Service log

    private var serviceLog: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Log", selection: $logFile) {
                    ForEach(model.monado?.installation.serviceLogURLs ?? [], id: \.self) { url in
                        Text(url.lastPathComponent).tag(Optional(url))
                    }
                }
                .frame(maxWidth: 320)
                Spacer()
                Button("Reload") { loadLog() }
                if let logFile {
                    Button("Open in Console") { model.open(logFile.path) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText.isEmpty ? "No log output." : logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(.background.secondary)
                .onChange(of: logText) { proxy.scrollTo("end") }
                .onAppear { proxy.scrollTo("end") }
            }
        }
        .onAppear {
            if logFile == nil { logFile = model.monado?.installation.serviceLogURLs.first }
            loadLog()
        }
        .onChange(of: logFile) { loadLog() }
    }

    private func loadLog() {
        guard let logFile else { logText = ""; return }
        logText = FileProbe.tail(logFile, maxBytes: 128 * 1024) ?? "The log file \(logFile.path) could not be read."
    }

    // MARK: Activity

    private var activityLog: some View {
        List(model.activity.reversed()) { entry in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(entry.level)).foregroundStyle(color(entry.level))
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(entry.message).textSelection(.enabled)
            }
        }
    }

    private func icon(_ level: ActivityEntry.Level) -> String {
        switch level { case .info: "info.circle"; case .warning: "exclamationmark.triangle"; case .error: "xmark.octagon" }
    }

    private func color(_ level: ActivityEntry.Level) -> Color {
        switch level { case .info: .secondary; case .warning: .orange; case .error: .red }
    }

    // MARK: Environment

    @ViewBuilder
    private var environment: some View {
        if let status = model.monado {
            Form {
                Section("LaunchAgent") {
                    LabeledContent("Label", value: MonadoInstallation.serviceLabel)
                    LabeledContent("Property list") { PathText(path: status.installation.agentPlistURL.path) }
                    if let job = status.job {
                        LabeledContent("Runs", value: job.runs.map(String.init) ?? "—")
                        LabeledContent("Last exit", value: [job.lastExitCode, job.lastTerminatingSignal].compactMap { $0 }.joined(separator: ", "))
                        LabeledContent("Mach services", value: job.machServices.joined(separator: ", "))
                    }
                    if let error = status.jobError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    LabeledContent("IPC socket") { PathText(path: status.socketPath, exists: status.socketFileExists) }
                    if let sockets = status.sockets {
                        LabeledContent("Listening", value: sockets.listeningPaths.isEmpty ? "No" : sockets.listeningPaths.joined(separator: ", "))
                        LabeledContent("Connected sockets", value: String(sockets.connectedCount))
                    }
                }
                Section("OpenXR runtime search") {
                    LabeledContent("Session XR_RUNTIME_JSON", value: status.registration.sessionOverride ?? "Not set")
                    LabeledContent("This app's XR_RUNTIME_JSON", value: status.registration.processOverride ?? "Not set")
                    ForEach(status.registration.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: candidate.exists ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(candidate.exists ? .green : .secondary)
                                Text(candidate.source.rawValue).font(.callout)
                                Spacer()
                                if let name = candidate.manifest?.name { Text(name).foregroundStyle(.secondary) }
                            }
                            PathText(path: candidate.url.path, exists: candidate.exists)
                            if let target = candidate.symlinkTarget {
                                Text("→ \(model.abbreviate(target))").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Client session variables (set at login)") {
                    let variables = status.installation.clientSessionVariables
                    if variables.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(variables.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        LabeledContent(key) { Text(value).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
                Section("Loaded service environment") {
                    let env = status.job?.environment ?? [:]
                    if env.isEmpty { Text("Not loaded").foregroundStyle(.secondary) }
                    ForEach(env.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        LabeledContent(key) { Text(value).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// A plain-text summary for bug reports.
@MainActor
enum DiagnosticReport {
    static func make(model: AppModel) -> String {
        var lines = ["Threshold XR diagnostic report", "Generated \(Date().formatted())", ""]
        if let status = model.monado {
            lines.append("Monado")
            lines.append("  Installed: \(status.installSummary.0) — \(status.installSummary.1)")
            lines.append("  Prefix: \(status.installation.prefix?.path ?? "—")")
            lines.append("  Service: \(status.serviceSummary.0) — \(status.serviceSummary.1)")
            lines.append("  Runtime: \(status.runtimeSummary.0) — \(status.runtimeSummary.1)")
            lines.append("  Headset: \(status.headsetSummary.0) — \(status.headsetSummary.1)")
            lines.append("  System runtime is Monado: \(status.isSystemRuntime)")
            lines.append("  Session XR_RUNTIME_JSON: \(status.registration.sessionOverride ?? "unset")")
            lines.append("  Pending reload: \(status.pendingEnvironmentChanges.joined(separator: ", "))")
            lines.append("")
        }
        lines.append("Components")
        for component in model.components {
            lines.append("  \(component.id.displayName): \(component.state.rawValue) \(component.version ?? "") \(component.location ?? "")")
            for note in component.notes where note.severity == .warning { lines.append("    ! \(note.text)") }
        }
        lines.append("")
        lines.append("Recent activity")
        for entry in model.activity.suffix(30) { lines.append("  \(entry.date.formatted(date: .omitted, time: .standard)) \(entry.message)") }
        return lines.joined(separator: "\n")
    }
}
