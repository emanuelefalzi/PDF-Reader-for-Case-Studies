import Foundation
import Testing
@testable import LelePdf

/// Repetitions (SPEC §7.5.4, M5a deliverable 5): later occurrences of the
/// same term, excluding the portions already covered by a real mark.
@Suite("Repetitions")
struct RepetitionsTests {
    private func block(_ id: String, page: Int, text: String) -> TextBlock {
        TextBlock(
            id: id, sectionPath: ["Sezione"], pageStart: page, pageEnd: page, cleanText: text,
            textHash: id, words: text.split(separator: " ").count,
            spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
            lineRectsByPage: [:]
        )
    }

    private func mark(_ id: String, termId: String, text: String, in blockText: String) -> Mark {
        let range = blockText.range(of: text)!
        let start = blockText.distance(from: blockText.startIndex, to: range.lowerBound)
        return Mark(id: id, termId: termId, type: .rectangle, text: text, source: .claude, page: 0, range: MarkRange(start: start, length: text.count))
    }

    @Test("a later occurrence in another block is found")
    func laterOccurrenceInOtherBlockFound() {
        let text1 = "La FDA ha approvato il farmaco."
        let text2 = "In seguito la FDA ha rivisto la decisione."
        let b1 = block("b1", page: 0, text: text1)
        let b2 = block("b2", page: 1, text: text2)

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [mark("m1", termId: "t1", text: "FDA", in: text1)])
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, marks: [])

        let occurrences = Repetitions.compute(blocks: [b1, b2], analysis: analysis)
        #expect(occurrences.count == 1)
        #expect(occurrences[0].blockId == "b2")
        #expect(occurrences[0].termId == "t1")
    }

    @Test("a portion already covered by a real mark in the same block is excluded")
    func rangeCoveredByRealMarkExcluded() {
        let text1 = "La FDA ha approvato il farmaco."
        let text2 = "La FDA ha rivisto la FDA più tardi."
        let b1 = block("b1", page: 0, text: text1)
        let b2 = block("b2", page: 1, text: text2)

        // In b2 the FIRST occurrence of "FDA" is a real (manual) mark; only
        // the second must count as a repetition.
        let firstRange = text2.range(of: "FDA")!
        let firstStart = text2.distance(from: text2.startIndex, to: firstRange.lowerBound)
        let realMarkInB2 = Mark(id: "m2", termId: "t1", type: .rectangle, text: "FDA", source: .manual, page: 1, range: MarkRange(start: firstStart, length: 3))

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [mark("m1", termId: "t1", text: "FDA", in: text1)])
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, marks: [realMarkInB2])

        let occurrences = Repetitions.compute(blocks: [b1, b2], analysis: analysis)
        #expect(occurrences.count == 1)
        #expect(occurrences[0].range.location > firstStart)
    }

    @Test("no occurrence before the block of the first mark")
    func noOccurrenceBeforeFirstBlock() {
        let text1 = "Testo senza il termine."
        let text2 = "La FDA compare qui per la prima volta."
        let b1 = block("b1", page: 0, text: text1)
        let b2 = block("b2", page: 1, text: text2)

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [])
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, marks: [mark("m1", termId: "t1", text: "FDA", in: text2)])

        let occurrences = Repetitions.compute(blocks: [b1, b2], analysis: analysis)
        #expect(occurrences.isEmpty)
    }

    @Test("word boundary: does not find 'FDA' inside 'FDAX'")
    func wordBoundaryRespected() {
        let occurrences = Repetitions.wordBoundaryOccurrences(of: "FDA", in: "Un termine FDAX non deve combaciare.")
        #expect(occurrences.isEmpty)
    }

    @Test("unanalyzed block: no repetition")
    func unanalyzedBlockIgnored() {
        let text1 = "La FDA ha approvato il farmaco."
        let text2 = "La FDA compare di nuovo qui."
        let b1 = block("b1", page: 0, text: text1)
        let b2 = block("b2", page: 1, text: text2)

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [mark("m1", termId: "t1", text: "FDA", in: text1)])
        analysis.blocks["b2"] = BlockAnalysis(status: .failed, marks: [])

        let occurrences = Repetitions.compute(blocks: [b1, b2], analysis: analysis)
        #expect(occurrences.isEmpty)
    }
}
