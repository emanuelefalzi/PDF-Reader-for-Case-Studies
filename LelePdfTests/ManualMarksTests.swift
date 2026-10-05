import Foundation
import Testing
@testable import LelePdf

/// Manual marks (SPEC §5.7, M7 brief deliverable 1): reused term registry,
/// links derived from the sentence, highlighting of manual terms in the
/// rewrite (deliverable 2). Pure logic: no `DocumentStore`/
/// `AnalysisController` here; integration is covered in
/// `AnalysisControllerManualMarksTests.swift`.
@Suite("ManualMarks")
struct ManualMarksTests {
    @Test("nextMarkId/nextLinkId: one more than the existing maximum")
    func nextIds() {
        let marks = [Mark(id: "m1", termId: "t1", type: .rectangle, text: "a", source: .claude, page: 0, range: MarkRange(start: 0, length: 1)),
                     Mark(id: "m5", termId: "t2", type: .circle, text: "b", source: .manual, page: 0, range: MarkRange(start: 2, length: 1))]
        #expect(ManualMarks.nextMarkId(in: marks) == "m6")
        #expect(ManualMarks.nextMarkId(in: []) == "m1")
        let links = [Link(id: "l3", from: "t1", to: "t2", label: "x", kind: .action, source: .claude)]
        #expect(ManualMarks.nextLinkId(in: links) == "l4")
    }

    @Test("makeMark: a new term mints a termId, normalizes whitespace (not case)")
    func makeMarkNewTerm() {
        let result = ManualMarks.makeMark(
            text: "Food   and Drug   Administration", type: .rectangle, page: 2, range: MarkRange(start: 5, length: 10), blockId: "b1",
            existingTerms: [:], existingMarks: []
        )
        #expect(result.mark.id == "m1")
        #expect(result.mark.source == .manual)
        #expect(result.mark.type == .rectangle)
        #expect(result.mark.text == "Food   and Drug   Administration")
        #expect(result.newTerm?.record.term == "Food and Drug Administration")
        #expect(result.newTerm?.record.firstBlockId == "b1")
        #expect(result.mark.termId == result.newTerm?.id)
    }

    @Test("makeMark: a term already in the glossary (case-insensitive) reuses the existing termId")
    func makeMarkReusesExistingTerm() {
        let existing = ["t7": TermRecord(term: "the fda", type: .rectangle, firstBlockId: "b0")]
        let result = ManualMarks.makeMark(
            text: "The FDA", type: .rectangle, page: 0, range: MarkRange(start: 0, length: 7), blockId: "b1",
            existingTerms: existing, existingMarks: []
        )
        #expect(result.mark.termId == "t7")
        #expect(result.newTerm == nil)
    }
}

@Suite("ManualLinkDerivation")
struct ManualLinkDerivationTests {
    @Test("sentenceRanges: splits on . ! ? followed by space/newline, not on an inner period (e.g. abbreviations are not handled here)")
    func sentenceRanges() {
        let text = "Prima frase. Seconda frase! Terza?"
        let ranges = ManualLinkDerivation.sentenceRanges(in: text)
        // The boundary falls right after the terminator (the whitespace
        // character that follows stays at the start of the next sentence):
        // this does not matter for `deriveLink`, which only looks at where a
        // mark's `range.start` falls (never a space).
        #expect(ranges.count == 3)
        #expect((text as NSString).substring(with: ranges[0]) == "Prima frase.")
        #expect((text as NSString).substring(with: ranges[1]) == " Seconda frase!")
        #expect((text as NSString).substring(with: ranges[2]) == " Terza?")
    }

    private func node(_ id: String, termId: String, type: MarkType, start: Int, length: Int, hidden: Bool = false) -> Mark {
        Mark(id: id, termId: termId, type: type, text: "x", source: .claude, page: 0, range: MarkRange(start: start, length: length), hidden: hidden)
    }

    @Test("deriveLink: a node before and one after in the same sentence become a link")
    func deriveLinkWithBothNodes() {
        let cleanText = "Il rialzo dei tassi ha causato una recessione. Altra frase."
        //                0         1         2         3         4
        let before = node("m1", termId: "t1", type: .rectangle, start: 3, length: 6) // "rialzo"
        let action = node("m2", termId: "t2", type: .underline, start: 24, length: 6) // "causato"
        let after = node("m3", termId: "t3", type: .circle, start: 34, length: 10) // "recessione"
        let link = ManualLinkDerivation.deriveLink(for: action, allMarks: [before, action, after], cleanText: cleanText)
        #expect(link?.from == "t1")
        #expect(link?.to == "t3")
    }

    @Test("deriveLink: no node before -> nil")
    func deriveLinkNoNodeBefore() {
        let cleanText = "Ha causato una recessione."
        let action = node("m2", termId: "t2", type: .arrow, start: 3, length: 7)
        let after = node("m3", termId: "t3", type: .circle, start: 15, length: 10)
        #expect(ManualLinkDerivation.deriveLink(for: action, allMarks: [action, after], cleanText: cleanText) == nil)
    }

    @Test("deriveLink: node before but in another sentence -> nil")
    func deriveLinkNodeInDifferentSentence() {
        let cleanText = "Un rialzo. Ha causato una recessione."
        let before = node("m1", termId: "t1", type: .rectangle, start: 3, length: 6)
        let action = node("m2", termId: "t2", type: .arrow, start: 14, length: 7)
        let after = node("m3", termId: "t3", type: .circle, start: 26, length: 10)
        #expect(ManualLinkDerivation.deriveLink(for: action, allMarks: [before, action, after], cleanText: cleanText) == nil)
    }

    @Test("deriveLink: a hidden mark does not count as a node")
    func deriveLinkIgnoresHiddenNode() {
        let cleanText = "Un rialzo ha causato una recessione."
        let before = node("m1", termId: "t1", type: .rectangle, start: 3, length: 6, hidden: true)
        let action = node("m2", termId: "t2", type: .arrow, start: 13, length: 7)
        let after = node("m3", termId: "t3", type: .circle, start: 25, length: 10)
        #expect(ManualLinkDerivation.deriveLink(for: action, allMarks: [before, action, after], cleanText: cleanText) == nil)
    }

    @Test("recomputeManualLinks: keeps Claude's links, recomputes only the manual ones")
    func recomputeKeepsClaudeLinks() {
        let cleanText = "Un rialzo ha causato una recessione."
        let before = node("m1", termId: "t1", type: .rectangle, start: 3, length: 6)
        let action = node("m2", termId: "t2", type: .arrow, start: 13, length: 7)
        let after = node("m3", termId: "t3", type: .circle, start: 25, length: 10)
        let claudeLink = Link(id: "l1", from: "t9", to: "t8", label: "altro", kind: .effect, source: .claude)
        let links = ManualLinkDerivation.recomputeManualLinks(existingLinks: [claudeLink], marks: [before, action, after], cleanText: cleanText)
        #expect(links.contains { $0.id == "l1" })
        #expect(links.contains { $0.from == "t1" && $0.to == "t3" && $0.source == .manual })
    }
}

@Suite("ManualMarks · highlighting in the rewrite")
struct ManualMarksHighlightTests {
    private func mark(_ text: String, termId: String, type: MarkType) -> Mark {
        Mark(id: "mx", termId: termId, type: type, text: text, source: .manual, page: 0, range: MarkRange(start: 0, length: text.count))
    }

    @Test("a manual term in plain text gets marked, case-insensitively")
    func highlightsCaseInsensitive() {
        let segments: [AnalysisController.ResolvedSegment] = [.plain("Il FDA ha approvato il farmaco.")]
        let result = ManualMarks.highlightManualTerms(in: segments, manualMarks: [mark("fda", termId: "t1", type: .rectangle)])
        // It also carries the real manual mark's `markId`, not just the
        // `termId`; otherwise hovering the mark in the PDF would light up this
        // occurrence only as "linked" (weak state) instead of as the exact
        // counterpart, which was the hover bug reported for manual marks.
        #expect(result.contains(.marked(text: "FDA", markId: "mx", termId: "t1", type: .rectangle)))
    }

    @Test("does not touch segments already marked by Claude")
    func doesNotTouchAlreadyMarkedSegments() {
        let segments: [AnalysisController.ResolvedSegment] = [.marked(text: "FDA", termId: "t9", type: .circle)]
        let result = ManualMarks.highlightManualTerms(in: segments, manualMarks: [mark("fda", termId: "t1", type: .rectangle)])
        #expect(result == segments)
    }

    @Test("no occurrence: the segment stays unchanged")
    func noOccurrenceLeavesSegmentUnchanged() {
        let segments: [AnalysisController.ResolvedSegment] = [.plain("Testo senza il termine.")]
        let result = ManualMarks.highlightManualTerms(in: segments, manualMarks: [mark("fda", termId: "t1", type: .rectangle)])
        #expect(result == segments)
    }
}
