import Foundation

/// A usage window (`unifiedWindows.five_hour`/`.seven_day` in the real
/// format).
struct RateLimitWindow: Sendable, Equatable {
    var utilization: Double
    var resetsAt: Date?
}

/// `rate_limit_event` from the real CLI (v2.1.26x, captured on 2026-09-16):
/// it arrives on EVERY chat turn, almost always with `status: "allowed"` and
/// low usage. The reported bug was that `ChatSession` read `status`/`resetsAt`
/// at the JSON root, while the real CLI nests them in `rate_limit_info`: the
/// result was always `nil`, hence a generic banner on every reply even at 27%
/// usage.
struct RateLimitInfo: Sendable, Equatable {
    var status: String?
    var resetsAt: Date?
    var rateLimitType: String?
    var fiveHour: RateLimitWindow?
    var sevenDay: RateLimitWindow?

    var maxUtilization: Double {
        max(fiveHour?.utilization ?? 0, sevenDay?.utilization ?? 0)
    }

    /// Reads the nested `rate_limit_info` (real format); if absent, falls back
    /// to the root keys ("legacy" format, never observed live but kept for
    /// backward compatibility).
    static func parse(_ json: [String: Any]) -> RateLimitInfo {
        let info = json["rate_limit_info"] as? [String: Any]
        let windows = info?["unifiedWindows"] as? [String: Any]
        return RateLimitInfo(
            status: (info?["status"] as? String) ?? (json["status"] as? String),
            resetsAt: epoch(info?["resetsAt"] ?? json["resetsAt"]),
            rateLimitType: info?["rateLimitType"] as? String,
            fiveHour: window(windows?["five_hour"]),
            sevenDay: window(windows?["seven_day"])
        )
    }

    private static func window(_ value: Any?) -> RateLimitWindow? {
        guard let dict = value as? [String: Any], let utilization = dict["utilization"] as? Double else { return nil }
        return RateLimitWindow(utilization: utilization, resetsAt: epoch(dict["resetsAt"]))
    }

    private static func epoch(_ value: Any?) -> Date? {
        guard let number = value as? Double else { return nil }
        return Date(timeIntervalSince1970: number)
    }
}
