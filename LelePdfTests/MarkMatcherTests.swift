import Foundation
import Testing
@testable import LelePdf

/// Matching a mark's text (SPEC §7.5 point 2, M5a deliverable 4): exact, then
/// case-insensitive, then tolerant; the occurrence following the one already
/// matched for the same text.
@Suite("MarkMatcher")
struct MarkMatcherTests {
    @Test("exact match")
    func exactMatch() {
        let text = "La FDA ha approvato il farmaco."
        let result = MarkMatcher.match(text: "FDA", in: Array(text), after: 0)
        #expect(result?.strategy == .exact)
        #expect(result.map { String(Array(text)[$0.range.location ..< $0.range.location + $0.range.length]) } == "FDA")
    }

    @Test("two marks with the same text: the second finds the next occurrence")
    func nextOccurrenceAfterSameText() throws {
        let text = "Merck ha investito. Poi Merck ha investito di nuovo."
        let chars = Array(text)
        let first = try #require(MarkMatcher.match(text: "Merck", in: chars, after: 0))
        let second = try #require(MarkMatcher.match(text: "Merck", in: chars, after: first.range.location + first.range.length))
        #expect(second.range.location > first.range.location)
        #expect(String(chars[second.range.location ..< second.range.location + second.range.length]) == "Merck")
    }

    @Test("case-insensitive when the exact match fails")
    func caseInsensitiveFallback() {
        let text = "la fda ha approvato il farmaco."
        let result = MarkMatcher.match(text: "FDA", in: Array(text), after: 0)
        #expect(result?.strategy == .caseInsensitive)
    }

    @Test("tolerant: a one-character typo in a token is still found")
    func tolerantMatchToleratesTypo() {
        // "aumentate" (mark) against "aumentato" (text): distance 1, within the
        // tolerance; "produzione" matches exactly. The mark's two tokens must
        // be adjacent in the text, as here.
        let text = "La compagnia ha aumentato produzione locale."
        let result = MarkMatcher.match(text: "aumentate produzione", in: Array(text), after: 0)
        #expect(result?.strategy == .tolerant)
    }

    @Test("no match within the tolerance: nil")
    func noMatchReturnsNil() {
        let text = "Testo completamente estraneo."
        let result = MarkMatcher.match(text: "Concetto assente", in: Array(text), after: 0)
        #expect(result == nil)
    }

    @Test("Levenshtein: correct distance on known examples")
    func levenshteinKnownDistances() {
        #expect(MarkMatcher.levenshtein("kitten", "sitting") == 3)
        #expect(MarkMatcher.levenshtein("stesso", "stesso") == 0)
        #expect(MarkMatcher.levenshtein("", "abc") == 3)
    }
}
