import SwiftUI
import ThresholdCore

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem
    @State private var confirmStop = false
    @State private var confirmStart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let status = model.monado {
                    statusGrid(status)
                    if let report = status.lastRun, report.hasProblems {
                        LastRunProblems(report: report, logPath: status.installation.agent?.standardErrorPath) {
                            selection = .diagnostics
                        }
                    }
                    serviceControls(status)
                    registration(status)
                    modes(status)
                } else {
                    ProgressView("Checking Monado…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
        }
    }

    // MARK: Status

    private func statusGrid(_ status: MonadoStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Monado runtime").font(.title2.weight(.semibold))
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    StatusCard(title: "Installation", systemImage: "externaldrive", summary: status.installSummary)
                    StatusCard(title: "Service", systemImage: "gearshape.2", summary: status.serviceSummary)
                }
                GridRow {
                    StatusCard(title: "Runtime", systemImage: "dot.radiowaves.left.and.right", summary: status.runtimeSummary)
                    StatusCard(title: "Headset", systemImage: "visionpro", summary: status.headsetSummary)
                }
            }
            Text("Checked \(status.checkedAt.formatted(date: .omitted, time: .standard))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Controls

    @ViewBuilder
    private func serviceControls(_ status: MonadoStatus) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    switch status.serviceState {
                    case .notLoaded:
                        Button("Load LaunchAgent") { model.perform(.load) }
                            .help("Register the existing LaunchAgent with launchd (launchctl bootstrap).")
                    case .notRegistered:
                        Text("Install Monado's LaunchAgent with monado-service-xpc-control install.")
                            .foregroundStyle(.secondary)
                    default:
                        Button {
                            confirmStart = true
                        } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .disabled(status.isServiceRunning || !status.installation.isInstalled)

                        Button {
                            if (status.connectedClientEstimate ?? 0) > 0 { confirmStop = true } else { model.perform(.stop) }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .disabled(!status.isServiceRunning)

                        Button {
                            model.perform(.restart)
                        } label: {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }
                        .disabled(!status.isServiceRunning)
                        .help("Stop the running service and start it again (launchctl kickstart -k).")

                        if model.offerForceStop && status.isServiceRunning {
                            Button("Force Stop", role: .destructive) { model.perform(.forceStop) }
                                .help("Send SIGKILL. Use only if Monado does not respond to Stop.")
                        }
                    }

                    Spacer()

                    if let action = model.busyAction {
                        ProgressView().controlSize(.small)
                        Text("\(action.rawValue)…").foregroundStyle(.secondary)
                    }
                }
                .disabled(model.busyAction != nil)

                Text(lifecycleNote(status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !status.pendingEnvironmentChanges.isEmpty {
                    Label("Saved Monado settings are waiting for a service reload.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                        .onTapGesture { selection = .settings }
                }
            }
            .padding(6)
        } label: {
            Text("Service").font(.headline)
        }
        .confirmationDialog("Start Monado without an application?", isPresented: $confirmStart) {
            Button("Start Monado") { model.perform(.start) }
        } message: {
            Text("A manually started service claims the headset and keeps running until you stop it, even with no applications connected. Applications normally start Monado automatically when they need it.")
        }
        .confirmationDialog("Stop Monado?", isPresented: $confirmStop) {
            Button("Stop Monado", role: .destructive) { model.perform(.stop) }
        } message: {
            Text("\(status.connectedClientEstimate ?? 0) connection(s) are open. Running XR applications will lose the runtime.")
        }
    }

    private func lifecycleNote(_ status: MonadoStatus) -> String {
        let idle = status.installation.agent?.environment["IPC_EXIT_WHEN_IDLE"] == "1"
        var note = "Monado runs under launchd, independently of Threshold XR. Quitting this app leaves it running."
        if idle {
            let delay = status.installation.agent?.environment["IPC_EXIT_WHEN_IDLE_DELAY_MS"] ?? "5000"
            note += " It exits \(delay) ms after the last application disconnects."
        }
        return note
    }

    // MARK: Registration

    private func registration(_ status: MonadoStatus) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("System runtime") {
                    if status.isSystemRuntime {
                        StatusPill(text: "Monado", tone: .good)
                    } else if let name = status.registration.activeRuntime?.manifest?.name {
                        StatusPill(text: name, tone: .caution)
                    } else {
                        StatusPill(text: "None registered", tone: .caution)
                    }
                }
                if let active = status.registration.activeRuntime {
                    LabeledContent("Active runtime file") { PathText(path: active.url.path) }
                }
                LabeledContent("Login session override") {
                    if let override = status.registration.sessionOverride {
                        PathText(path: override)
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                }
                Text("Threshold XR does not change the system OpenXR registration. Applications started from Finder, the Dock or a terminal find Monado through the standard loader.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        } label: {
            Text("OpenXR registration").font(.headline)
        }
    }

    // MARK: Modes

    private func modes(_ status: MonadoStatus) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ModeRow(
                    title: "Runtime only",
                    systemImage: "cpu",
                    detail: "Monado serves OpenXR applications started any way you like. Nothing else is required."
                ) {
                    StatusPill(text: status.isSessionRuntime ? "Available" : "Runtime not selected", tone: status.isSessionRuntime ? .good : .caution)
                }
                Divider()
                ModeRow(
                    title: "Threshold Home",
                    systemImage: "house.lodge",
                    detail: "The immersive SwiftXR home in the headset. It launches applications and returns when they exit."
                ) {
                    Button("Open Threshold Home") { model.launchThresholdHome() }
                        .disabled(!model.thresholdHomeAvailable)
                }
                Divider()
                ModeRow(
                    title: "Direct launch",
                    systemImage: "arrow.up.forward.app",
                    detail: "Start one application straight into the headset, without the home environment."
                ) {
                    Button("Applications") { selection = .applications }
                }
            }
            .padding(6)
        } label: {
            Text("Ways to use Threshold").font(.headline)
        }
    }
}

/// Problems from Monado's most recent run, so a failed start is visible
/// even after the service has exited again.
private struct LastRunProblems: View {
    @Environment(AppModel.self) private var model
    let report: MonadoRunReport
    let logPath: String?
    let showDiagnostics: () -> Void
    @State private var showAll = false

    var body: some View {
        let shown = showAll ? report.problems : Array(report.problems.prefix(2))
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text("Monado's last run had problems").font(.headline)
                ForEach(shown, id: \.self) { problem in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(problem.summary)
                        Text(problem.logLine)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(problem.logLine)
                    }
                }
                Text(caption).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if report.problems.count > 2 {
                        Button(showAll ? "Show fewer" : "Show all \(report.problems.count)") { showAll.toggle() }
                            .buttonStyle(.link)
                    }
                    Button("Service log", action: showDiagnostics).buttonStyle(.link)
                    if let logPath {
                        Button("Open in Console") { model.open(logPath) }.buttonStyle(.link)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.6)))
    }

    private var caption: String {
        var parts: [String] = []
        if let tag = report.buildTag { parts.append("Build \(tag)") }
        if let modified = report.logModified {
            parts.append("log written \(modified.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct StatusCard: View {
    let title: String
    let systemImage: String
    let summary: (String, String, Tone)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(summary.2.color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(summary.0).font(.title3.weight(.semibold))
                Text(summary.1)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .accessibilityElement(children: .combine)
    }
}

private struct ModeRow<Accessory: View>: View {
    let title: String
    let systemImage: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            accessory
        }
    }
}
