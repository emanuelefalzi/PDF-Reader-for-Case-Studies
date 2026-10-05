import Foundation
import Testing
@testable import LelePdf

/// Parsing of `rate_limit_event`: the line below is exactly the event
/// captured from the real CLI on 2026-09-16 (v2.1.26x), as provided by the
/// user.
@Suite("RateLimitInfo")
struct RateLimitInfoTests {
    private static let realCapture = """
    {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1789584600,\
    "rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"org_level_disabled",\
    "isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.27,"resetsAt":1789584600},\
    "seven_day":{"utilization":0.37,"resetsAt":1789941600}}},"uuid":"u1","session_id":"s1"}
    """

    private func decode(_ text: String) throws -> [String: Any] {
        let data = try #require(text.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("real nested event: status/resetsAt/windows read from rate_limit_info")
    func parsesRealNestedCapture() throws {
        let info = RateLimitInfo.parse(try decode(Self.realCapture))
        #expect(info.status == "allowed")
        #expect(info.rateLimitType == "five_hour")
        #expect(info.resetsAt == Date(timeIntervalSince1970: 1_789_584_600))
        #expect(info.fiveHour == RateLimitWindow(utilization: 0.27, resetsAt: Date(timeIntervalSince1970: 1_789_584_600)))
        #expect(info.sevenDay == RateLimitWindow(utilization: 0.37, resetsAt: Date(timeIntervalSince1970: 1_789_941_600)))
        #expect(info.maxUtilization == 0.37)
    }

    @Test("legacy format (root-level keys): status/resetsAt still read, no windows")
    func parsesLegacyTopLevelFormat() throws {
        let json = try decode(#"{"type":"rate_limit_event","status":"rejected","resetsAt":1789584600}"#)
        let info = RateLimitInfo.parse(json)
        #expect(info.status == "rejected")
        #expect(info.resetsAt == Date(timeIntervalSince1970: 1_789_584_600))
        #expect(info.fiveHour == nil)
        #expect(info.sevenDay == nil)
        #expect(info.maxUtilization == 0)
    }

    @Test("nested rate_limit_info always takes precedence over root-level keys")
    func nestedTakesPrecedenceOverRoot() throws {
        let json = try decode(#"""
        {"type":"rate_limit_event","status":"rejected","resetsAt":1,
         "rate_limit_info":{"status":"allowed","resetsAt":1789584600}}
        """#)
        let info = RateLimitInfo.parse(json)
        #expect(info.status == "allowed")
        #expect(info.resetsAt == Date(timeIntervalSince1970: 1_789_584_600))
    }
}
