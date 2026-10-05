import Foundation

/// What to do with the chat banner when a `rate_limit_event` arrives:
/// `.clear` removes a previous banner, `.ignore` leaves the state as it is
/// (unknown status: only logged in `ChatSession`).
enum ChatRateLimitBannerAction: Sendable, Equatable {
    case show(String)
    case clear
    case ignore
}

/// Banner rules (verified against the real CLI on 2026-09-16): `status`
/// almost always arrives as "allowed" with low usage, so no banner in that
/// case. `ChatController` used to always show "Claude is close to the usage
/// limit or has reached it." because it read fields that were always `nil`
/// (see `RateLimitInfo`).
enum ChatRateLimitBanner {
    /// Above this usage threshold, "allowed" still becomes a gentle warning
    /// (utilization ≥ 0.8).
    private static let warningThreshold = 0.8

    static func action(for info: RateLimitInfo) -> ChatRateLimitBannerAction {
        switch info.status {
        case "allowed":
            return info.maxUtilization >= warningThreshold ? .show(warningText(info)) : .clear
        case "allowed_warning":
            return .show(warningText(info))
        case "rejected":
            return .show(rejectedText(info))
        default:
            return .ignore
        }
    }

    private static func warningText(_ info: RateLimitInfo) -> String {
        guard let dominant = dominantWindow(info) else {
            return String(localized: "You are close to the usage limit.")
        }
        let percent = Int((dominant.window.utilization * 100).rounded())
        guard let resetsAt = dominant.window.resetsAt ?? info.resetsAt else {
            return String(localized: "You are at \(percent)% of the usage limit (\(dominant.label)).")
        }
        return String(localized: "You are at \(percent)% of the usage limit (\(dominant.label)) \u{b7} resets at \(timeText(resetsAt))")
    }

    private static func rejectedText(_ info: RateLimitInfo) -> String {
        guard let resetsAt = info.resetsAt ?? dominantWindow(info)?.window.resetsAt else {
            return String(localized: "Usage limit reached.")
        }
        return String(localized: "Usage limit reached \u{b7} try again after \(timeText(resetsAt))")
    }

    /// The window with the highest utilization (on a tie the 5-hour one wins:
    /// it resets sooner, so it is the more relevant one to show).
    private static func dominantWindow(_ info: RateLimitInfo) -> (label: String, window: RateLimitWindow)? {
        switch (info.fiveHour, info.sevenDay) {
        case (nil, nil): return nil
        case (let five?, nil): return (String(localized: "5-hour window"), five)
        case (nil, let week?): return (String(localized: "weekly window"), week)
        case (let five?, let week?):
            return five.utilization >= week.utilization ? (String(localized: "5-hour window"), five) : (String(localized: "weekly window"), week)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    private static func timeText(_ date: Date) -> String { timeFormatter.string(from: date) }
}
