import Foundation
import Testing
@testable import LelePdf

/// `BlockSegmenter.segment(paragraphs:tocEntries:granularity:)`, on
/// synthetic paragraphs/contents -- a block runs from one contents entry of
/// the chosen level (or higher) to the next, "by paragraph" ignores the
/// contents, and the length caps stay those of the chosen granularity.
@Suite("Summary granularity")
struct BlockSegmenterGranularityTests {
    /// Five pages, with a three-level contents: T1 at p.0, T2 at p.1 and
    /// p.3, T3 at p.2 and p.4 -- one short paragraph per page.
    private func tocEntries() -> [TocEntry] {
        [
            TocEntry(id: "t1", title: "Chapter 1", level: 1, page: 0),
            TocEntry(id: "t2a", title: "1.1", level: 2, page: 1),
            TocEntry(id: "t3a", title: "1.1.1", level: 3, page: 2),
            TocEntry(id: "t2b", title: "1.2", level: 2, page: 3),
            TocEntry(id: "t3b", title: "1.2.1", level: 3, page: 4),
        ]
    }

    private func paragraphs(wordsPerPage: Int = 30) -> [Paragraph] {
        (0 ..< 5).map { page in PipelineFixtures.paragraph(page: page, text: PipelineFixtures.words(wordsPerPage)) }
    }

    @Test("Paragraph: one block per paragraph, contents ignored")
    func paragraphGranularityIgnoresToc() {
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs(), tocEntries: tocEntries(), granularity: .paragraph)
        #expect(blocks.count == 5)
        for block in blocks { #expect(block.partIndex == nil) }
    }

    @Test("Heading 3: boundary at every entry of level ≤ 3 -- here equivalent to one block per page")
    func heading3GranularityBoundsAtEveryEntry() {
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs(), tocEntries: tocEntries(), granularity: .heading3)
        #expect(blocks.count == 5)
        #expect(blocks.map(\.pageStart) == [0, 1, 2, 3, 4])
    }

    @Test("Heading 2: boundary only at entries of level ≤ 2 -- p.0 stays a block of its own, p.1-2 merge, p.3-4 merge")
    func heading2GranularityMergesFinerEntries() {
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs(), tocEntries: tocEntries(), granularity: .heading2)
        // Boundaries of level ≤2: p.0 (T1), p.1 (T2a), p.3 (T2b). p.2 (T3a,
        // ignored at this granularity) stays in the group opened by p.1; p.4 (T3b,
        // ignored) stays in the group opened by p.3.
        #expect(blocks.map(\.pageStart) == [0, 1, 3])
        #expect(blocks[1].pageEnd == 2)
        #expect(blocks[2].pageEnd == 4)
    }

    @Test("Chapter: only T1 counts, the whole document in a single block (no parts, below the cap)")
    func chapterGranularityUsesOnlyLevel1() {
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs(), tocEntries: tocEntries(), granularity: .chapter)
        #expect(blocks.count == 1)
        #expect(blocks[0].pageStart == 0)
        #expect(blocks[0].pageEnd == 4)
        #expect(blocks[0].partIndex == nil)
    }

    @Test("Chapter: a section longer than the cap (2800 words) is split into parts of 900-2000")
    func chapterGranularitySplitsAboveCap() {
        // 6 paragraphs of 700 words = 4200, beyond `chapter.caps.sectionMaxWords` (2800).
        let paragraphs = (0 ..< 6).map { _ in PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(700)) }
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs, tocEntries: [], granularity: .chapter)
        #expect(blocks.count >= 2)
        let caps = SummaryGranularity.chapter.caps
        for (index, block) in blocks.enumerated() {
            if index < blocks.count - 1 { #expect(block.words >= caps.partMinWords) }
            #expect(block.words <= caps.partMaxWords)
            #expect(block.partIndex == index + 1)
            #expect(block.partCount == blocks.count)
        }
    }

    @Test("Heading 2: a section longer than the cap (1400 words) is split into parts of 500-1100")
    func heading2GranularitySplitsAboveCap() {
        let paragraphs = (0 ..< 6).map { _ in PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(400)) }
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs, tocEntries: [], granularity: .heading2)
        #expect(blocks.count >= 2)
        let caps = SummaryGranularity.heading2.caps
        for block in blocks { #expect(block.words <= caps.partMaxWords) }
    }

    @Test("No contents entry at the chosen level: the whole document is a single section (declared fallback)")
    func noBoundaryEntriesFallsBackToWholeDocument() {
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs(), tocEntries: [], granularity: .chapter)
        #expect(blocks.count == 1)
        #expect(blocks[0].pageStart == 0)
        #expect(blocks[0].pageEnd == 4)
    }

    @Test("Paragraphs before any contents entry form a group of their own")
    func paragraphsBeforeFirstEntryFormTheirOwnGroup() {
        let entries = [TocEntry(id: "t1", title: "Chapter 1", level: 1, page: 2)]
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs(), tocEntries: entries, granularity: .chapter)
        #expect(blocks.count == 2)
        #expect(blocks[0].pageStart == 0)
        #expect(blocks[0].pageEnd == 1)
        #expect(blocks[1].pageStart == 2)
        #expect(blocks[1].pageEnd == 4)
    }

    @Test("A block never cuts a paragraph, whatever the granularity")
    func neverSplitsAParagraph() {
        let longParagraphs = [
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(60)),
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(3000)),
        ]
        let blocks = BlockSegmenter.segment(paragraphs: longParagraphs, tocEntries: [], granularity: .chapter)
        #expect(blocks.contains { $0.words >= 3000 })
    }
}
