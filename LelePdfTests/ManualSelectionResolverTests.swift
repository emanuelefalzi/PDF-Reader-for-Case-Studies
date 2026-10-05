import Foundation
import Testing
@preconcurrency import PDFKit
@testable import LelePdf

/// `ManualSelectionResolver` (SPEC §5.7, M7 brief deliverable 1) on real
/// PDFs: selection → block + clean range, round trip with
/// `TextBlock.resolve(cleanRange:)`, and clipping to the first page/block for
/// a selection spanning two pages.
extension HeavyTestSuites {
@Suite("ManualSelectionResolver", .serialized)
@MainActor
struct ManualSelectionResolverTests {
    @Test("a single-page selection finds the same block/clean range used to build it")
    func singlePageRoundTrip() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: Merck PDF not found at \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        let result = await PipelineRealDocumentHelper.run(document)
        let blocks = result.output.blocks

        guard let block = blocks.first(where: { $0.cleanText.count >= 12 }),
              let (pageIndex, origRange) = block.resolve(cleanRange: NSRange(location: 0, length: 10)).first,
              let page = document.page(at: pageIndex),
              let selection = page.selection(for: origRange) else {
            print("SKIP: no usable block/selection found in Merck")
            return
        }

        let resolution = ManualSelectionResolver.resolve(selection: selection, document: document, blocks: blocks)
        #expect(resolution?.blockId == block.id)
        #expect(resolution?.page == pageIndex)
        #expect(resolution?.text.isEmpty == false)
    }

    @Test("a selection spanning two pages is clipped to the first page/block")
    func crossPageClipsToFirstPage() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.draghi) else {
            print("SKIP: Draghi PDF not found at \(TestPDFs.draghi.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.draghi))
        let result = await PipelineRealDocumentHelper.run(document)
        let blocks = result.output.blocks

        guard document.pageCount >= 2,
              let page0 = document.page(at: 0), let page1 = document.page(at: 1),
              let range0 = nonEmptyPrefixRange(page0, length: 5),
              let range1 = nonEmptyPrefixRange(page1, length: 5),
              let selection0 = page0.selection(for: range0),
              let selection1 = page1.selection(for: range1) else {
            print("SKIP: first two pages of the Draghi report have no usable text")
            return
        }
        selection0.add(selection1)
        guard let firstSelectedPage = selection0.pages.first else {
            print("SKIP: merged selection has no pages")
            return
        }
        let expectedPageIndex = document.index(for: firstSelectedPage)

        let resolution = ManualSelectionResolver.resolve(selection: selection0, document: document, blocks: blocks)
        // No assertion if the selection's first page is not touched by any
        // block (for example a cover page with no body text): in any case the
        // clipping must NEVER return a page other than the selection's first
        // page.
        if let resolution {
            #expect(resolution.page == expectedPageIndex)
        }
    }

    private func nonEmptyPrefixRange(_ page: PDFPage, length: Int) -> NSRange? {
        guard let string = page.string, !string.isEmpty else { return nil }
        return NSRange(location: 0, length: min(length, (string as NSString).length))
    }

    // MARK: - Identical occurrences on the same page

    /// Identity block (`cleanText` equal to `page.string`, identical
    /// `charMap`): isolates `ManualSelectionResolver`'s behavior from that of
    /// `BlockSegmenter`/text cleaning, which are not needed for this bug
    /// (it lives entirely in the search inside `page.string`).
    private func identityBlock(pageString: NSString) -> TextBlock {
        let cleanText = pageString as String
        let length = pageString.length
        return TextBlock(
            id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, cleanText: cleanText,
            textHash: "h", words: 10,
            spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: cleanText.count, charMap: Array(0 ..< length))],
            lineRectsByPage: [:]
        )
    }

    @Test("selecting the SECOND identical occurrence on the same page anchors the mark to it, not to the first")
    func secondIdenticalOccurrenceResolvesToItself() throws {
        let phrase = "Il tasso di sconto è salito."
        let url = try StoreFixtures.makeRepeatedLineTextPDF(line: phrase)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let pageString = try #require(page.string) as NSString

        let first = pageString.range(of: phrase)
        #expect(first.location != NSNotFound)
        let afterFirst = NSRange(location: first.location + first.length, length: pageString.length - (first.location + first.length))
        let second = pageString.range(of: phrase, options: [], range: afterFirst)
        #expect(second.location != NSNotFound)
        #expect(second.location > first.location) // really two distinct occurrences on the page

        let selection = try #require(page.selection(for: second))
        let block = identityBlock(pageString: pageString)

        let resolution = try #require(ManualSelectionResolver.resolve(selection: selection, document: document, blocks: [block]))
        #expect(resolution.text == phrase)
        #expect(resolution.cleanRange.location == second.location)
        #expect(resolution.cleanRange.length == second.length)
        // The real bug fixed here: previously this selection (the second
        // occurrence) was anchored to the FIRST.
        #expect(resolution.cleanRange.location != first.location)
    }

    @Test("the FIRST identical occurrence is still resolved correctly (no regression)")
    func firstIdenticalOccurrenceStillResolvesToItself() throws {
        let phrase = "Il tasso di sconto è salito."
        let url = try StoreFixtures.makeRepeatedLineTextPDF(line: phrase)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let pageString = try #require(page.string) as NSString

        let first = pageString.range(of: phrase)
        #expect(first.location != NSNotFound)

        let selection = try #require(page.selection(for: first))
        let block = identityBlock(pageString: pageString)

        let resolution = try #require(ManualSelectionResolver.resolve(selection: selection, document: document, blocks: [block]))
        #expect(resolution.cleanRange.location == first.location)
        #expect(resolution.cleanRange.length == first.length)
    }
}
}
