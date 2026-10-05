import Foundation
import Testing
@testable import LelePdf

/// Pure banner rules: no fake CLI, just `RateLimitInfo` →
/// `ChatRateLimitBannerAction` ("allowed low → no banner; allowed high →
/// percent banner; rejected → limit banner with time; legacy top-level
/// format still parsed").
@Suite("ChatRateLimitBanner")
struct ChatRateLimitBannerTests {
    private func info(
        status: String?, resetsAt: Date? = nil,
        fiveHour: RateLimitWindow? = nil, sevenDay: RateLimitWindow? = nil
    ) -> RateLimitInfo {
        RateLimitInfo(status: status, resetsAt: resetsAt, rateLimitType: "five_hour", fiveHour: fiveHour, sevenDay: sevenDay)
    }

    @Test("allowed with low usage: no banner, a previous banner is cleared")
    func allowedLowClearsBanner() {
        let action = ChatRateLimitBanner.action(for: info(
            status: "allowed",
            fiveHour: RateLimitWindow(utilization: 0.27, resetsAt: nil),
            sevenDay: RateLimitWindow(utilization: 0.37, resetsAt: nil)
        ))
        #expect(action == .clear)
    }

    @Test("allowed with high usage: banner with the percentage of the dominant window")
    func allowedHighShowsPercent() {
        let resetsAt = Date(timeIntervalSince1970: 1_789_584_600)
        let action = ChatRateLimitBanner.action(for: info(
            status: "allowed",
            fiveHour: RateLimitWindow(utilization: 0.85, resetsAt: resetsAt),
            sevenDay: RateLimitWindow(utilization: 0.5, resetsAt: nil)
        ))
        guard case .show(let text) = action else {
            Issue.record("expected a banner, found \(action)")
            return
        }
        #expect(text.contains("85%"))
        #expect(text.contains("5-hour window"))
        #expect(text.contains("resets at"))
    }

    @Test("rejected: banner with the limit reached and the time")
    func rejectedShowsLimitReached() {
        let resetsAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970 + 3600)
        let action = ChatRateLimitBanner.action(for: info(status: "rejected", resetsAt: resetsAt))
        guard case .show(let text) = action else {
            Issue.record("expected a banner, found \(action)")
            return
        }
        #expect(text.contains("Usage limit reached"))
        #expect(text.contains("try again after"))
    }

    @Test("unknown status: no action (only a log on the ChatSession side)")
    func unknownStatusIsIgnored() {
        #expect(ChatRateLimitBanner.action(for: info(status: "qualcosa_di_nuovo")) == .ignore)
        #expect(ChatRateLimitBanner.action(for: info(status: nil)) == .ignore)
    }

    @Test("legacy format (without unifiedWindows): the text still uses the top-level resetsAt")
    func legacyFormatStillProducesBanner() {
        let resetsAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970 + 3600)
        let action = ChatRateLimitBanner.action(for: info(status: "rejected", resetsAt: resetsAt))
        guard case .show(let text) = action else {
            Issue.record("expected a banner even without the nested windows")
            return
        }
        #expect(text.contains("Usage limit reached"))
    }
}
