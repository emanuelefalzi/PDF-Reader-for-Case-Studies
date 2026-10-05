import Foundation
import Testing
@testable import LelePdf

/// Headings (SPEC §7.3), on synthetic pages that imitate exactly the font
/// pattern of the real Merck case (inspected with
/// `PDFPage.attributedString`): body Palatino-Roman 9.96; title-page title
/// Palatino-Bold 18.96 (a single page); section headings Palatino-Bold 12.96
/// (level 1); subsection headings Palatino-Italic 12.0 (level 2, no bold:
/// they go through the size rule, not the short-bold rule); Exhibit captions
/// Palatino-Bold 9.96 (same size as the body, must not become headings);
/// repeated header Palatino-Bold 8.04.
@Suite("Pipeline · headings")
struct HeadingDetectorTests {
    private static let pageRect = PageRect(x: 0, y: 0, width: 600, height: 800)

    /// 6 synthetic pages: title page (title + 1st section), then alternating
    /// sections and subsections, plus an Exhibit caption and a short bold
    /// reference code with no letters (Merck p.1 "9-707-509").
    private static func merckLikePages() -> [CleanPage] {
        func body(_ page: Int, _ line: Int, _ y: CGFloat, _ text: String? = nil) -> CleanLine {
            PipelineFixtures.cleanLine(page: page, lineIndex: line, text: text ?? PipelineFixtures.words(30), y: y, fontSize: 9.96)
        }

        let page0 = CleanPage(pageIndex: 0, pageRect: pageRect, lines: [
            PipelineFixtures.cleanLine(page: 0, lineIndex: 0, text: "Strategy in the Twenty-First Century Pharmaceutical Industry", y: 760, fontSize: 18.96, isBold: true),
            PipelineFixtures.cleanLine(page: 0, lineIndex: 1, text: "Industry Size and Composition", y: 700, fontSize: 12.96, isBold: true),
            body(0, 2, 650),
        ])
        let page1 = CleanPage(pageIndex: 1, pageRect: pageRect, lines: [
            PipelineFixtures.cleanLine(page: 1, lineIndex: 0, text: "Developing a Drug", y: 760, fontSize: 12.96, isBold: true),
            body(1, 1, 700),
        ])
        let page2 = CleanPage(pageIndex: 2, pageRect: pageRect, lines: [
            PipelineFixtures.cleanLine(page: 2, lineIndex: 0, text: "The Process", y: 760, fontSize: 12.0, isBold: false),
            body(2, 1, 700),
        ])
        let page3 = CleanPage(pageIndex: 3, pageRect: pageRect, lines: [
            PipelineFixtures.cleanLine(page: 3, lineIndex: 0, text: "Burgeoning Biotech", y: 760, fontSize: 12.0, isBold: false),
            body(3, 1, 700),
        ])
        let page4 = CleanPage(pageIndex: 4, pageRect: pageRect, lines: [
            PipelineFixtures.cleanLine(page: 4, lineIndex: 0, text: "Manufacturing Drugs", y: 760, fontSize: 12.96, isBold: true),
            body(4, 1, 700),
            PipelineFixtures.cleanLine(page: 4, lineIndex: 2, text: "Exhibit 1", y: 300, fontSize: 9.96, isBold: true),
            body(4, 3, 260, "Source data follows in the table below for this exhibit."),
        ])
        let page5 = CleanPage(pageIndex: 5, pageRect: pageRect, lines: [
            PipelineFixtures.cleanLine(page: 5, lineIndex: 0, text: "9-707-509", y: 780, fontSize: 10.56, isBold: true),
            body(5, 1, 700),
        ])
        return [page0, page1, page2, page3, page4, page5]
    }

    @Test("body text is the most common size (9.96 rounded to 10)")
    func bodyFontSizeMatchesDominantSize() {
        let body = HeadingDetector.bodyFontSize(Self.merckLikePages())
        #expect(body == 10.0)
    }

    @Test("section headings (Palatino-Bold 12.96) are detected at level 1")
    func level1HeadingsDetected() {
        let pages = Self.merckLikePages()
        let body = HeadingDetector.bodyFontSize(pages)
        let headings = HeadingDetector.detect(pages: pages, bodyFontSize: body)
        let level1 = headings.filter { $0.level == 1 }.map(\.text)
        #expect(level1.contains("Industry Size and Composition"))
        #expect(level1.contains("Developing a Drug"))
        #expect(level1.contains("Manufacturing Drugs"))
    }

    @Test("italic subsection headings (Palatino-Italic 12.0) are detected at level 2")
    func level2HeadingsDetected() {
        let pages = Self.merckLikePages()
        let body = HeadingDetector.bodyFontSize(pages)
        let headings = HeadingDetector.detect(pages: pages, bodyFontSize: body)
        let level2 = headings.filter { $0.level == 2 }.map(\.text)
        #expect(level2.contains("The Process"))
        #expect(level2.contains("Burgeoning Biotech"))
    }

    @Test("the title-page title (18.96, a single page) does not consume level 1 and does not become a section heading")
    func frontispieceTitleDoesNotSkewRanking() {
        let pages = Self.merckLikePages()
        let body = HeadingDetector.bodyFontSize(pages)
        let headings = HeadingDetector.detect(pages: pages, bodyFontSize: body)
        // Before the fix, the title-page title alone occupied level 1 in the
        // ranking and "Industry Size and Composition" ended up at level 2
        // (observed bug: the generated contents had a single entry). Now the
        // title, appearing on a single page, does not enter the ranking at
        // all and does not generate a `Heading`.
        #expect(!headings.contains { $0.text.contains("Twenty-First Century") })
        #expect(headings.first { $0.text == "Industry Size and Composition" }?.level == 1)
    }

    @Test("the reported pages and levels are correct")
    func headingsHaveCorrectPagesAndLevels() {
        let pages = Self.merckLikePages()
        let body = HeadingDetector.bodyFontSize(pages)
        let headings = HeadingDetector.detect(pages: pages, bodyFontSize: body)
        let byText = Dictionary(uniqueKeysWithValues: headings.map { ($0.text, $0) })
        #expect(byText["Industry Size and Composition"]?.pageIndex == 0)
        #expect(byText["Developing a Drug"]?.pageIndex == 1)
        #expect(byText["The Process"]?.pageIndex == 2)
        #expect(byText["Burgeoning Biotech"]?.pageIndex == 3)
        #expect(byText["Manufacturing Drugs"]?.pageIndex == 4)
    }

    @Test("a short bold Exhibit caption does not become a heading if its lines are excluded")
    func exhibitCaptionExcludedWhenMarked() {
        let pages = Self.merckLikePages()
        let body = HeadingDetector.bodyFontSize(pages)
        // As `TextPipeline` would (it now detects Exhibits before headings):
        // the "Exhibit 1" line on page 4 (index 2) is excluded.
        let excluded: [Int: Set<Int>] = [4: [2]]
        let headings = HeadingDetector.detect(pages: pages, bodyFontSize: body, excludedLines: excluded)
        #expect(!headings.contains { $0.text == "Exhibit 1" })
    }

    @Test("without the exclusion, the same Exhibit caption would satisfy the short-bold rule (shows why the exclusion is needed)")
    func exhibitCaptionLeaksWithoutExclusion() {
        let pages = Self.merckLikePages()
        let body = HeadingDetector.bodyFontSize(pages)
        let headings = HeadingDetector.detect(pages: pages, bodyFontSize: body)
        #expect(headings.contains { $0.text == "Exhibit 1" })
    }

    @Test("a short bold reference code with no letters does not become a heading")
    func numericOnlyBoldLineIsNotAHeading() {
        let pages = Self.merckLikePages()
        let body = HeadingDetector.bodyFontSize(pages)
        let headings = HeadingDetector.detect(pages: pages, bodyFontSize: body)
        #expect(!headings.contains { $0.text == "9-707-509" })
    }

    @Test("a printed table-of-contents page with dot leaders produces no headings")
    func printedIndexPageProducesNoHeadings() {
        var pages = Self.merckLikePages()
        // Extra page, like the Draghi "Contents": several lines with dot
        // leaders at the same size as real headings elsewhere.
        let indexPage = CleanPage(pageIndex: 6, pageRect: Self.pageRect, lines: [
            PipelineFixtures.cleanLine(page: 6, lineIndex: 0, text: "Industry Size and Composition . . . . . . . . . . . . . 1", y: 760, fontSize: 12.96, isBold: true),
            PipelineFixtures.cleanLine(page: 6, lineIndex: 1, text: "Developing a Drug . . . . . . . . . . . . . . . . . . . . 2", y: 700, fontSize: 12.96, isBold: true),
        ])
        pages.append(indexPage)
        let body = HeadingDetector.bodyFontSize(pages)
        let headings = HeadingDetector.detect(pages: pages, bodyFontSize: body)
        #expect(!headings.contains { $0.pageIndex == 6 })
        // The real entries, on their real pages, are still detected.
        #expect(headings.contains { $0.text == "Industry Size and Composition" && $0.pageIndex == 0 })
    }
}
