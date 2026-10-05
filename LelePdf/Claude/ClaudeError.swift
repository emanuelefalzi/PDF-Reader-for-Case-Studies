import Foundation

/// Errors of the Claude layer (SPEC §5.5 "Errors", §5.12), with messages
/// ready for the UI (the app interface is in English).
enum ClaudeError: Error, Sendable, Equatable {
    case cliNotFound
    case notLoggedIn
    case usageLimit(resetsAt: Date?)
    case network
    case timeout
    case invalidResponse
    case cancelled
    case processFailed(stderrTail: String)

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    /// Message for the UI (SPEC §5.5): shown in the analysis card with
    /// "Retry", or in Claude's status banner.
    var userMessage: String {
        switch self {
        case .cliNotFound:
            return String(localized: "Claude CLI not found. Install it or set the path in Settings.")
        case .notLoggedIn:
            return String(localized: "You are not signed in to Claude. Run \u{201c}claude auth login\u{201d} in Terminal.")
        case .usageLimit(let resetsAt):
            if let resetsAt {
                return String(localized: "Usage limit reached. Try again after \(Self.timeFormatter.string(from: resetsAt)).")
            }
            return String(localized: "Usage limit reached.")
        case .network:
            return String(localized: "No network connection.")
        case .timeout:
            return String(localized: "No response within 120 s.")
        case .invalidResponse:
            return String(localized: "Invalid response from Claude.")
        case .cancelled:
            return String(localized: "Cancelled.")
        case .processFailed(let tail):
            return tail.isEmpty ? String(localized: "The Claude CLI exited with an error.") : String(localized: "The Claude CLI exited with an error: \(tail)")
        }
    }
}

/// Recognizes error cases from the text returned by the CLI (SPEC §5.5):
/// there is no dedicated field in the JSON envelope, only patterns in the
/// `result` text or in stderr, verified against the real CLI (SPEC §4) and
/// imitated by the fake CLI (`scripts/fake-claude/claude`).
enum ClaudeErrorMapper {
    /// `"Claude AI usage limit reached|<epoch>"`, or a text that names the
    /// limit generically if the epoch format is not recognized.
    static func usageLimit(in text: String) -> ClaudeError? {
        if let range = text.range(of: #"usage limit reached\|(\d+)"#, options: .regularExpression) {
            let matched = text[range]
            if let pipeIndex = matched.firstIndex(of: "|") {
                let epochText = matched[matched.index(after: pipeIndex)...]
                if let epoch = TimeInterval(epochText) {
                    return .usageLimit(resetsAt: Date(timeIntervalSince1970: epoch))
                }
            }
            return .usageLimit(resetsAt: nil)
        }
        let lower = text.lowercased()
        if lower.contains("usage limit") || lower.contains("rate limit") {
            return .usageLimit(resetsAt: nil)
        }
        return nil
    }

    /// "Invalid API key", "Please run /login", "not logged in", "authentication".
    static func isNotLoggedIn(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("invalid api key")
            || lower.contains("please run /login")
            || lower.contains("not logged in")
            || lower.contains("authentication")
    }

    /// "ENOTFOUND", "ECONNREFUSED", "network", "getaddrinfo", "fetch failed".
    static func isNetwork(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("enotfound")
            || lower.contains("econnrefused")
            || lower.contains("network")
            || lower.contains("getaddrinfo")
            || lower.contains("fetch failed")
    }

    /// To be used when a process exits with a non-zero status (or times out):
    /// decides which `ClaudeError` to show by looking at stdout+stderr
    /// together, in the order limit → not logged in → network → generic with
    /// the stderr tail.
    static func map(result: ProcessRunResult) -> ClaudeError {
        if result.timedOut { return .timeout }
        let combined = result.stdout + "\n" + result.stderr
        if let limit = usageLimit(in: combined) { return limit }
        if isNotLoggedIn(combined) { return .notLoggedIn }
        if isNetwork(combined) { return .network }
        return .processFailed(stderrTail: result.tail())
    }
}
