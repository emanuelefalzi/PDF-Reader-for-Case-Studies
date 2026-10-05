import Foundation
import Testing
@testable import LelePdf

/// Index map of a block (SPEC §7.3, last point): a range of the clean text
/// resolves to one or more (page, original range) pairs; a mark spanning two
/// pages produces two pairs. Pure, no PDFKit: the comparison with
/// `page.selection(for:)` on the real PDFs is in
/// `TextPipelineIntegrationTests`.
@Suite("Pipeline · block index map")
struct BlockIndexMapTests {
    /// Block with two spans: page 3 (original characters 100-109), page 4
    /// (original characters 0-7), like a paragraph that continues from one
    /// page to the next.
    private static func crossPageBlock() -> TextBlock {
        let spanA = BlockPageSpan(page: 3, cleanStart: 0, cleanLength: 10, charMap: Array(100 ..< 110))
        let spanB = BlockPageSpan(page: 4, cleanStart: 10, cleanLength: 8, charMap: Array(0 ..< 8))
        return TextBlock(
            id: "test", sectionPath: ["Sezione"], pageStart: 3, pageEnd: 4,
            cleanText: "0123456789ABCDEFGH", textHash: "hash", words: 2,
            spans: [spanA, spanB], lineRectsByPage: [:]
        )
    }

    @Test("a range entirely on the first page resolves a single pair")
    func rangeWithinFirstPage() {
        let block = Self.crossPageBlock()
        let result = block.resolve(cleanRange: NSRange(location: 2, length: 3))
        #expect(result.count == 1)
        #expect(result[0].page == 3)
        #expect(result[0].range == NSRange(location: 102, length: 3))
    }

    @Test("a range spanning two pages resolves two pairs")
    func rangeSpanningTwoPages() {
        let block = Self.crossPageBlock()
        let result = block.resolve(cleanRange: NSRange(location: 8, length: 4))
        #expect(result.count == 2)
        #expect(result[0].page == 3)
        #expect(result[0].range == NSRange(location: 108, length: 2))
        #expect(result[1].page == 4)
        #expect(result[1].range == NSRange(location: 0, length: 2))
    }

    @Test("a range entirely on the second page resolves a single pair")
    func rangeWithinSecondPage() {
        let block = Self.crossPageBlock()
        let result = block.resolve(cleanRange: NSRange(location: 12, length: 3))
        #expect(result.count == 1)
        #expect(result[0].page == 4)
        #expect(result[0].range == NSRange(location: 2, length: 3))
    }
}
