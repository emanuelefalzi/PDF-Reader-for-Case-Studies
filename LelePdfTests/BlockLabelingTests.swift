import Foundation
import Testing
@testable import LelePdf

/// Human-readable label of a block, e.g. "3.2".
@Suite("BlockLabeling")
struct BlockLabelingTests {
    private func block(_ id: String, page: Int) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: "x", textHash: id, words: 1, spans: [], lineRectsByPage: [:])
    }

    @Test("chapter and index within the chapter")
    func chapterAndWithinChapterIndex() {
        let blocks = [
            block("b1", page: 0), block("b2", page: 1), // Chapter 1 (p. 0-4)
            block("b3", page: 5), block("b4", page: 6), block("b5", page: 7), // Chapter 2 (p. 5+)
        ]
        let toc = [
            TocEntry(id: "c1", title: "Capitolo 1", level: 1, page: 0),
            TocEntry(id: "c2", title: "Capitolo 2", level: 1, page: 5),
        ]
        #expect(BlockLabeling.humanLabel(blockId: "b1", blocks: blocks, level1TocEntries: toc) == "1.1")
        #expect(BlockLabeling.humanLabel(blockId: "b2", blocks: blocks, level1TocEntries: toc) == "1.2")
        #expect(BlockLabeling.humanLabel(blockId: "b3", blocks: blocks, level1TocEntries: toc) == "2.1")
        #expect(BlockLabeling.humanLabel(blockId: "b5", blocks: blocks, level1TocEntries: toc) == "2.3")
    }

    @Test("no chapter contains the block: chapter 0")
    func noChapterContainsBlockUsesZero() {
        let blocks = [block("b1", page: 0)]
        #expect(BlockLabeling.humanLabel(blockId: "b1", blocks: blocks, level1TocEntries: []) == "0.1")
    }

    @Test("block before the first chapter: chapter 0")
    func blockBeforeFirstChapterUsesZero() {
        let blocks = [block("b1", page: 0), block("b2", page: 3)]
        let toc = [TocEntry(id: "c1", title: "Capitolo 1", level: 1, page: 3)]
        #expect(BlockLabeling.humanLabel(blockId: "b1", blocks: blocks, level1TocEntries: toc) == "0.1")
        #expect(BlockLabeling.humanLabel(blockId: "b2", blocks: blocks, level1TocEntries: toc) == "1.1")
    }
}
