import Foundation
import Testing
@testable import LelePdf

/// `TocHeadingMatch` (reported problem: with two headings on the same page,
/// the click always goes to the first): pure matching of a generated entry →
/// detected `Heading`, to fill in `pageY`.
@Suite("TocHeadingMatch")
struct TocHeadingMatchTests {
    /// `y` is the desired `maxY` of the rectangle (top edge of the line, page
    /// space): the rectangle is built below it, so `y` in the tests directly
    /// coincides with the `rect.maxY` that `TocHeadingMatch` reads.
    private func heading(_ text: String, page: Int, y: CGFloat, level: Int = 1) -> Heading {
        Heading(pageIndex: page, lineIndex: 0, text: text, level: level, rect: CGRect(x: 0, y: y - 12, width: 100, height: 12))
    }

    @Test("equal (normalized) title → pageY of the right heading, not of the first on the page")
    func exactMatchPicksRightHeadingAmongTwoOnSamePage() {
        let headings = [
            heading("Introduzione", page: 3, y: 700),
            heading("Metodologia", page: 3, y: 400),
        ]
        #expect(TocHeadingMatch.pageY(forTitle: "Metodologia", pageIndex: 3, headings: headings) == 400)
        #expect(TocHeadingMatch.pageY(forTitle: "Introduzione", pageIndex: 3, headings: headings) == 700)
    }

    @Test("the comparison ignores case and extra whitespace (SPEC normalization)")
    func matchIsCaseAndWhitespaceInsensitive() {
        let headings = [heading("The   Process", page: 2, y: 550)]
        #expect(TocHeadingMatch.pageY(forTitle: "the process", pageIndex: 2, headings: headings) == 550)
    }

    @Test("title cleaned up by Claude (shortened): containment as a fallback")
    func containmentFallbackForCleanedTitle() {
        let headings = [heading("3.2 Manufacturing Drugs: An Overview", page: 4, y: 300)]
        #expect(TocHeadingMatch.pageY(forTitle: "Manufacturing Drugs", pageIndex: 4, headings: headings) == 300)
    }

    @Test("a single heading on the page and no textual similarity: it is used anyway")
    func singleCandidateFallback() {
        let headings = [heading("Merck & Co.", page: 8, y: 600)]
        #expect(TocHeadingMatch.pageY(forTitle: "Un titolo completamente diverso", pageIndex: 8, headings: headings) == 600)
    }

    @Test("no heading on the page → nil (the caller falls back to the page jump alone)")
    func noHeadingsOnPageReturnsNil() {
        #expect(TocHeadingMatch.pageY(forTitle: "Qualcosa", pageIndex: 5, headings: []) == nil)
    }

    @Test("several headings on the page, none similar: no forced match")
    func ambiguousMultipleCandidatesReturnsNil() {
        let headings = [
            heading("Primo", page: 1, y: 700),
            heading("Secondo", page: 1, y: 400),
        ]
        #expect(TocHeadingMatch.pageY(forTitle: "Terzo", pageIndex: 1, headings: headings) == nil)
    }
}
