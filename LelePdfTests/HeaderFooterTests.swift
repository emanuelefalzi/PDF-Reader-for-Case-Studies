import Foundation
import Testing
@testable import LelePdf

/// Removal of headers/footers (SPEC §7.2.1) and extraction of chapter
/// candidates from headers (SPEC §7.4 point 1), on synthetic pages imitating
/// the Draghi report (letter-spaced header, different tail per chapter) and
/// the Merck case (identical license line on every page, page numbers).
@Suite("Pipeline · headers and footers")
struct HeaderFooterTests {
    private static let pageRect = PageRect(x: 0, y: 0, width: 600, height: 800)

    /// 10 pages: letter-spaced header with the same title but a different
    /// chapter ("CHAPTER 2" for the first 5, "CHAPTER 3" for the rest),
    /// normal body text, page number at the bottom.
    private static func draghiLikePages() -> [CleanPage] {
        (0 ..< 10).map { pageIndex in
            let chapter = pageIndex < 5 ? 2 : 3
            let header = PipelineFixtures.cleanLine(
                page: pageIndex, lineIndex: 0,
                text: "T H E F U T U R E O F E U R O P E A N C O M P E T I T I V E N E S S — PA RT A | C H A PT E R \(chapter)",
                y: 780
            )
            let body = PipelineFixtures.cleanLine(page: pageIndex, lineIndex: 1, text: "Questo è il corpo del testo della pagina.", y: 400)
            let footer = PipelineFixtures.cleanLine(page: pageIndex, lineIndex: 2, text: "\(pageIndex + 1)", y: 20)
            return CleanPage(pageIndex: pageIndex, pageRect: pageRect, lines: [header, body, footer])
        }
    }

    @Test("Draghi header removed on all synthetic pages")
    func draghiHeaderRemoved() {
        let result = HeaderFooterRemover.apply(to: Self.draghiLikePages())
        for page in result.pages {
            #expect(page.lines[0].removedAsHeaderFooter, "header not removed on page \(page.pageIndex)")
            #expect(!page.lines[1].removedAsHeaderFooter)
            #expect(page.lines[2].removedAsHeaderFooter, "page number not removed on page \(page.pageIndex)")
        }
    }

    @Test("chapter candidates extracted from the header before removal")
    func chapterCandidatesExtracted() {
        let result = HeaderFooterRemover.apply(to: Self.draghiLikePages())
        let titles = Set(result.chapterCandidates.map(\.title))
        #expect(titles.contains("Chapter 2"))
        #expect(titles.contains("Chapter 3"))
        #expect(result.chapterCandidates.first { $0.title == "Chapter 2" }?.page == 0)
        #expect(result.chapterCandidates.first { $0.title == "Chapter 3" }?.page == 5)
    }

    @Test("repeated license line removed on all pages (Merck case)")
    func licenseLineRemoved() {
        let pages = (0 ..< 8).map { pageIndex -> CleanPage in
            let license = PipelineFixtures.cleanLine(
                page: pageIndex, lineIndex: 0,
                text: "This document is authorized for use only by a student at a university.",
                y: 780
            )
            let body = PipelineFixtures.cleanLine(page: pageIndex, lineIndex: 1, text: "Testo normale del caso.", y: 400)
            return CleanPage(pageIndex: pageIndex, pageRect: Self.pageRect, lines: [license, body])
        }
        let result = HeaderFooterRemover.apply(to: pages)
        for page in result.pages {
            #expect(page.lines[0].removedAsHeaderFooter)
            #expect(!page.lines[1].removedAsHeaderFooter)
        }
    }

    @Test("a body line that appears only once is not removed")
    func uniqueLineNotRemoved() {
        var pages = Self.draghiLikePages()
        // Replaces the body of a single page with unique text, in the margin:
        // it must not reach the 30% repetition threshold.
        pages[0].lines[1] = PipelineFixtures.cleanLine(page: 0, lineIndex: 1, text: "Frase unica non ripetuta.", y: 780)
        let result = HeaderFooterRemover.apply(to: pages)
        // The unique line at the top of page 0 must not be removed: it is
        // neither the recurring header nor a page number.
        #expect(result.pages[0].lines.contains { $0.text.string == "Frase unica non ripetuta." && !$0.removedAsHeaderFooter })
    }
}
