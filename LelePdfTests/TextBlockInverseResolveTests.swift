import Foundation
import Testing
@testable import LelePdf

/// `TextBlock.inverseResolve` (M7 deliverable 1, the inverse of
/// `resolve(cleanRange:)` already tested in `BlockIndexMapTests`): from a
/// range of **original** characters (`page.string`) to the corresponding
/// range in the clean text. Pure, no PDFKit; the comparison with a real
/// `PDFSelection` is in `ManualSelectionResolverTests`.
@Suite("Pipeline · inverseResolve")
struct TextBlockInverseResolveTests {
    /// Same test block as `BlockIndexMapTests`: two spans, page 3 (original
    /// characters 100-109) and page 4 (original characters 0-7).
    private static func crossPageBlock() -> TextBlock {
        let spanA = BlockPageSpan(page: 3, cleanStart: 0, cleanLength: 10, charMap: Array(100 ..< 110))
        let spanB = BlockPageSpan(page: 4, cleanStart: 10, cleanLength: 8, charMap: Array(0 ..< 8))
        return TextBlock(
            id: "test", sectionPath: ["Sezione"], pageStart: 3, pageEnd: 4,
            cleanText: "0123456789ABCDEFGH", textHash: "hash", words: 2,
            spans: [spanA, spanB], lineRectsByPage: [:]
        )
    }

    @Test("inverse of a range inside the first span")
    func inverseWithinFirstSpan() {
        let block = Self.crossPageBlock()
        let result = block.inverseResolve(page: 3, origRange: NSRange(location: 102, length: 3))
        #expect(result == NSRange(location: 2, length: 3))
    }

    @Test("inverse of a range inside the second span")
    func inverseWithinSecondSpan() {
        let block = Self.crossPageBlock()
        let result = block.inverseResolve(page: 4, origRange: NSRange(location: 2, length: 3))
        #expect(result == NSRange(location: 12, length: 3))
    }

    @Test("it really is the inverse of resolve(cleanRange:) on every span")
    func isInverseOfResolve() {
        let block = Self.crossPageBlock()
        for cleanRange in [NSRange(location: 2, length: 3), NSRange(location: 12, length: 3)] {
            for (page, origRange) in block.resolve(cleanRange: cleanRange) {
                #expect(block.inverseResolve(page: page, origRange: origRange) == cleanRange)
            }
        }
    }

    @Test("page not touched by the block: nil")
    func pageNotTouchedReturnsNil() {
        let block = Self.crossPageBlock()
        #expect(block.inverseResolve(page: 0, origRange: NSRange(location: 0, length: 3)) == nil)
    }

    @Test("range outside the page's span: nil")
    func rangeOutsideSpanReturnsNil() {
        let block = Self.crossPageBlock()
        #expect(block.inverseResolve(page: 3, origRange: NSRange(location: 500, length: 3)) == nil)
    }
}
