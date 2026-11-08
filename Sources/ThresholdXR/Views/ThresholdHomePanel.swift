import AppKit
import SwiftUI
import ThresholdCore

/// Threshold Home's status and controls, as the Shell's status window and
/// Mode/Input menus used to provide them.
struct ThresholdHomePanel: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let status = model.homeStatus {
                    running(status)
                } else {
                    stopped
                }
            }
            .padding(6)
        } label: {
            HStack {
                Text("Threshold Home").font(.headline)
                if let busy = model.homeBusy {
                    ProgressView().controlSize(.small)
                    Text("\(busy.rawValue)…").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
        .confirmationDialog("Stop Threshold Home?", isPresented: $confirmStop) {
            Button("Stop Home", role: .destructive) { model.stopThresholdHome() }
        } message: {
            Text("\(model.homeStatus?.foreground ?? "An application") is in the foreground. Applications Home launched keep running; Monado keeps running.")
        }
    }

    // MARK: Not running

    private var stopped: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "house.lodge")
                .font(.title)
                .foregroundStyle(.secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Not running").font(.title3.weight(.semibold))
                Text("The immersive home in the headset: launch apps, watch video, use your Mac's desktop. Applications also run without it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                model.launchThresholdHome()
            } label: {
                Label("Start Home", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.thresholdHomeAvailable || model.homeBusy != nil)
        }
    }

    // MARK: Running

    @ViewBuilder
    private func running(_ status: HomeStatus) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon(for: status.mode))
                .font(.title)
                .foregroundStyle(tone(for: status.mode).color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("In the headset").font(.subheadline).foregroundStyle(.secondary)
                Text(status.foreground).font(.title2.weight(.semibold))
                Text(status.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(role: .destructive) {
                if status.mode == .external || status.canStopApp { confirmStop = true } else { model.stopThresholdHome() }
            } label: {
                Label("Stop Home", systemImage: "stop.fill")
            }
            .disabled(model.homeBusy != nil)
        }

        if let notice = status.notice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if let permission = status.missingPermission {
                            Button("Open \(permission.rawValue) Settings") {
                                NSWorkspace.shared.open(permission.settingsURL)
                            }
                            Button("Restart Home") { model.restartThresholdHome() }
                                .help("macOS applies a new permission when Home starts again.")
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }

        HStack(spacing: 8) {
            modeButton("Home", "house", .home, command: .home,
                       enabled: status.canGoHome, current: status)
            modeButton("Video", "play.rectangle", .video, command: .video,
                       enabled: status.canSwitchModes, current: status)
            modeButton("Desktop", "desktopcomputer", .desktop, command: .desktop,
                       enabled: status.canSwitchModes, current: status)
            modeButton("Browser", "globe", .browser, command: .browser,
                       enabled: status.canSwitchModes, current: status)
        }

        HStack(spacing: 8) {
            Button {
                model.sendToHome(.recenter)
            } label: {
                Label("Recenter", systemImage: "scope")
            }
            Toggle(isOn: Binding(get: { status.mouseCaptureEnabled }, set: { _ in model.sendToHome(.toggleMouse) })) {
                Label("Capture Mouse in Headset", systemImage: "cursorarrow.rays")
            }
            .toggleStyle(.button)
            .help("When on, the Mac's mouse drives the headset pointer. ⇧⌘M also toggles it while Home is frontmost.")
            if status.canStopApp {
                Button(role: .destructive) {
                    model.sendToHome(.stopApp)
                } label: {
                    Label("Stop \(status.mode == .external ? status.foreground : "Launched App")", systemImage: "xmark.circle")
                }
            }
            if status.canRetryConnection {
                Button {
                    model.sendToHome(.retryConnection)
                } label: {
                    Label("Retry Headset", systemImage: "arrow.clockwise")
                }
            }
            Spacer()
        }

        Text("\(status.runtime) · \(status.input)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func modeButton(_ title: String, _ systemImage: String, _ mode: HomeStatus.Mode,
                            command: HomeCommand, enabled: Bool, current: HomeStatus) -> some View {
        let isCurrent = current.mode == mode
        return Button {
            model.sendToHome(command)
        } label: {
            Label(title, systemImage: systemImage)
                .frame(minWidth: 84)
        }
        .buttonStyle(.bordered)
        .tint(isCurrent ? .accentColor : nil)
        .background(isCurrent ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .disabled(isCurrent || !enabled)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func icon(for mode: HomeStatus.Mode) -> String {
        switch mode {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .unavailable: "exclamationmark.triangle"
        case .home: "house.fill"
        case .video: "play.rectangle.fill"
        case .desktop: "desktopcomputer"
        case .browser: "globe"
        case .external: "visionpro"
        }
    }

    private func tone(for mode: HomeStatus.Mode) -> Tone {
        switch mode {
        case .connecting: .caution
        case .unavailable: .bad
        default: .good
        }
    }
}
