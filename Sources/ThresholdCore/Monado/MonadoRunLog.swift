import Foundation

/// What Monado's service log says about its most recent run.
///
/// The log has no timestamps, so a run is the text after the last
/// "starting up..." line Monado prints at startup.
public struct MonadoRunReport: Sendable, Equatable {
    /// The build tag the run reported, e.g. `v25.1.0-2487-g5559edb41`.
    public var buildTag: String?
    /// Whether the run reached "Server exiting".
    public var ended: Bool
    /// Plain-language problems recognised in the run, most important first.
    public var problems: [Problem]
    /// When the log was last written.
    public var logModified: Date?

    public struct Problem: Sendable, Equatable, Hashable {
        public var summary: String
        /// The log line it came from.
        public var logLine: String
    }

    public var hasProblems: Bool { !problems.isEmpty }
}

public enum MonadoRunLog {
    /// Known failure lines, with what they mean. Order sets priority.
    static let knownProblems: [(needle: String, summary: String)] = [
        ("WSI physical mode did not settle", "The compositor could not switch the headset display to the requested refresh rate."),
        ("Failed to init compositor", "Monado's compositor failed to start, so applications get no XR system."),
        ("Failed to claim USB", "Monado could not claim one of the headset's USB interfaces; a previous attempt or another app may still hold it."),
        ("HMD device creation failed", "Monado could not open the PS VR2 headset."),
        ("ipc_client_check_git_tag", "An application's Monado client does not match the installed service's build."),
        ("XRT_ERROR_DEVICE_CREATION_FAILED", "Monado could not create the headset device."),
        ("XRT_ERROR_VULKAN", "Monado's Vulkan setup failed."),
    ]

    public static func lastRun(in url: URL, maxBytes: Int = 512 * 1024) -> MonadoRunReport? {
        guard let text = FileProbe.tail(url, maxBytes: maxBytes) else { return nil }
        var report = parseLastRun(text)
        report?.logModified = FileProbe.modificationDate(url)
        return report
    }

    public static func parseLastRun(_ text: String) -> MonadoRunReport? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let start = lines.lastIndex(where: { $0.contains("starting up...") }) else { return nil }
        let run = lines[start...]

        var tag: String?
        if let quoteStart = run.first?.firstIndex(of: "'"),
           let quoteEnd = run.first?[run.first!.index(after: quoteStart)...].firstIndex(of: "'") {
            tag = String(run.first![run.first!.index(after: quoteStart)..<quoteEnd])
        }

        var problems: [MonadoRunReport.Problem] = []
        for (needle, summary) in knownProblems {
            if let line = run.first(where: { $0.contains(needle) }),
               !problems.contains(where: { $0.summary == summary }) {
                problems.append(.init(summary: summary, logLine: line.trimmingCharacters(in: .whitespaces)))
            }
        }
        // Any other ERROR line still counts, shown as-is.
        if problems.isEmpty, let line = run.first(where: { $0.hasPrefix("ERROR") }) {
            problems.append(.init(summary: "Monado reported an error.", logLine: line.trimmingCharacters(in: .whitespaces)))
        }
        return MonadoRunReport(
            buildTag: tag,
            ended: run.contains { $0.contains("Server exiting") },
            problems: problems,
            logModified: nil
        )
    }
}
