import Foundation
import Testing
@testable import LelePdf

/// Block rule ("block = section", an author decision), on synthetic
/// paragraphs: a section (delimited by the lowest-level heading up to the
/// next) is a single block within the length threshold; beyond that, it is
/// split into numbered parts; never cross a section, never cut a
/// paragraph.
@Suite("Pipeline · blocks")
struct BlockSegmentationTests {
    @Test("a section up to 700 words is a single block, without a part number")
    func shortSectionIsOneBlock() {
        let paragraphs = [
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(100), sectionPath: ["Capitolo 1"]),
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(200), sectionPath: ["Capitolo 1"]),
        ]
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs)
        #expect(blocks.count == 1)
        #expect(blocks[0].words <= 700)
        #expect(blocks[0].partIndex == nil)
        #expect(blocks[0].partCount == nil)
    }

    @Test("a longer section is split into numbered parts of 250 to 600 words")
    func longSectionSplitsIntoNumberedParts() {
        // 6 paragraphs of 200 words = 1200 words in total, beyond the threshold
        // of 700: it must split into at least 2 blocks, each between 250 and 600
        // words (the last may be shorter, the remainder of the section), numbered
        // "part 1 of N" .. "part N of N" in text order.
        let paragraphs = (0 ..< 6).map { _ in
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(200), sectionPath: ["Sezione"])
        }
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs)
        #expect(blocks.count >= 2)
        for (index, block) in blocks.enumerated() {
            if index < blocks.count - 1 {
                #expect(block.words >= BlockSegmenter.partMinWords)
            }
            #expect(block.words <= BlockSegmenter.partMaxWords)
            #expect(block.partIndex == index + 1)
            #expect(block.partCount == blocks.count)
        }
    }

    @Test("a single paragraph beyond 700 words is a part on its own")
    func longParagraphIsOwnBlock() {
        let paragraphs = [
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(120), sectionPath: ["Sezione"]),
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(900), sectionPath: ["Sezione"]),
            PipelineFixtures.paragraph(page: 1, text: PipelineFixtures.words(120), sectionPath: ["Sezione"]),
        ]
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs)
        #expect(blocks.contains { $0.words >= 900 })
    }

    @Test("a block never crosses a section boundary")
    func blockNeverCrossesSection() {
        let paragraphs = [
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(50), sectionPath: ["Capitolo 1"]),
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(50), sectionPath: ["Capitolo 2"]),
        ]
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs)
        #expect(blocks.count == 2)
        #expect(blocks[0].sectionPath == ["Capitolo 1"])
        #expect(blocks[1].sectionPath == ["Capitolo 2"])
    }

    @Test("a change at the lowest heading level already opens a new section/block")
    func lowestLevelHeadingChangeStartsNewSection() {
        // Same chapter (level 1) and same section (level 2), but a different
        // subsection (level 3, the lowest): the block boundary must already
        // trigger at this level, not only at the higher levels.
        let paragraphs = [
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(50), sectionPath: ["Capitolo 1", "3.1", "3.1.1"]),
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(50), sectionPath: ["Capitolo 1", "3.1", "3.1.2"]),
        ]
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs)
        #expect(blocks.count == 2)
        #expect(blocks[0].sectionPath.last == "3.1.1")
        #expect(blocks[1].sectionPath.last == "3.1.2")
    }

    @Test("stable id and text hash, different for different blocks")
    func idAndHashAreDeterministic() {
        let paragraphs = [PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(50), sectionPath: ["Capitolo 1"])]
        let first = BlockSegmenter.segment(paragraphs: paragraphs)
        let second = BlockSegmenter.segment(paragraphs: paragraphs)
        #expect(first[0].id == second[0].id)
        #expect(first[0].textHash == second[0].textHash)

        let other = BlockSegmenter.segment(paragraphs: [
            PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(50, prefix: "altro"), sectionPath: ["Capitolo 1"]),
        ])
        #expect(other[0].textHash != first[0].textHash)
    }
}
