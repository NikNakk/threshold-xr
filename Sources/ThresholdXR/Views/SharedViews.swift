import SwiftUI
import ThresholdCore

/// Semantic tone used for status colours (system colours adapt to light/dark).
enum Tone {
    case good, neutral, caution, bad, inactive

    var color: Color {
        switch self {
        case .good: .green
        case .neutral: .blue
        case .caution: .orange
        case .bad: .red
        case .inactive: .secondary
        }
    }
}

struct StatusPill: View {
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(tone.color)
            .background(tone.color.opacity(0.14), in: Capsule())
            .accessibilityLabel(text)
    }
}

/// A placeholder for screens or features scheduled for a later milestone.
struct PlaceholderNotice: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hammer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A path that can be revealed in Finder and copied.
struct PathText: View {
    @Environment(AppModel.self) private var model
    let path: String
    var exists: Bool = true

    var body: some View {
        Text(model.abbreviate(path))
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .foregroundStyle(exists ? .primary : .secondary)
            .strikethrough(!exists)
            .lineLimit(2)
            .truncationMode(.middle)
            .help(path)
            .contextMenu {
                Button("Reveal in Finder") { model.reveal(path) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
    }
}

extension DetectionState {
    var tone: Tone {
        switch self {
        case .detected: .good
        case .partial: .caution
        case .notFound: .inactive
        }
    }
}

extension MonadoStatus {
    var installSummary: (String, String, Tone) {
        switch installState {
        case .installed:
            return ("Installed", installation.buildTag ?? "Version unknown", .good)
        case .missingServiceExecutable:
            return ("Incomplete", "The LaunchAgent points to a missing monado-service.", .bad)
        case .notInstalled:
            return ("Not installed", "No Monado installation was found.", .inactive)
        }
    }

    var serviceSummary: (String, String, Tone) {
        switch serviceState {
        case .notRegistered:
            return ("Not registered", "No LaunchAgent; applications cannot start Monado on demand.", .inactive)
        case .notLoaded:
            return ("Not loaded", "The LaunchAgent exists but is not loaded in this login session.", .caution)
        case .idle:
            var detail = "Idle. Starts automatically when an OpenXR application connects."
            if let job, job.lastExitWasAbnormal {
                detail = "Idle. The last run ended abnormally (\(job.lastExitCode ?? job.lastTerminatingSignal ?? "unknown"))."
                return ("Idle", detail, .caution)
            }
            return ("Idle", detail, .neutral)
        case let .running(pid):
            return ("Running", "Process \(pid)", .good)
        case let .unknown(text):
            return ("Unknown", text, .caution)
        }
    }

    var runtimeSummary: (String, String, Tone) {
        switch runtimeState {
        case .stopped:
            return ("Not running", "Applications connect through the standard OpenXR loader.", .inactive)
        case .starting:
            return ("Starting", "The service is running but not yet listening.", .caution)
        case .ready:
            let clients = connectedClientEstimate.map { $0 == 1 ? "1 connection" : "\($0) connections" } ?? "connections unknown"
            return ("Ready", "Listening for applications · \(clients)", .good)
        case .unverified:
            return ("Running", "Socket present; readiness could not be verified.", .caution)
        }
    }

    var headsetSummary: (String, String, Tone) {
        switch headsetState {
        case let .activeInRuntime(name):
            return ("In use", name, .good)
        case .connected:
            return ("Connected", "PS VR2 is on USB.", .neutral)
        case .notDetected:
            let detail = headsetUSB.otherSonyDevices.isEmpty
                ? "Not detected on USB."
                : "Headset not found; another Sony USB device is present (adapter or controller)."
            return ("Not connected", detail, .inactive)
        }
    }
}
