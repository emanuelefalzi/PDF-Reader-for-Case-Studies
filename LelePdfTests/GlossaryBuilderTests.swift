import Foundation
import Testing
@testable import LelePdf

/// Order and cut-off of the glossary (SPEC §7.5: "up to 60, the most recent
/// and frequent").
@Suite("GlossaryBuilder")
struct GlossaryBuilderTests {
    private func mark(_ id: String, termId: String) -> Mark {
        Mark(id: id, termId: termId, type: .rectangle, text: "x", source: .claude, page: 0, range: MarkRange(start: 0, length: 1))
    }

    @Test("more frequent comes before less frequent")
    func moreFrequentComesFirst() {
        var analysis = AnalysisRecord()
        analysis.terms = [
            "t1": TermRecord(term: "Raro", type: .rectangle, firstBlockId: "b1"),
            "t2": TermRecord(term: "Frequente", type: .rectangle, firstBlockId: "b1"),
        ]
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [mark("m1", termId: "t1"), mark("m2", termId: "t2"), mark("m3", termId: "t2")])

        let result = GlossaryBuilder.build(analysis: analysis, blockOrder: ["b1"])
        #expect(result.map(\.termId) == ["t2", "t1"])
    }

    @Test("on equal frequency the most recent wins")
    func mostRecentWinsOnTie() {
        var analysis = AnalysisRecord()
        analysis.terms = [
            "t1": TermRecord(term: "Vecchio", type: .rectangle, firstBlockId: "b1"),
            "t2": TermRecord(term: "Nuovo", type: .rectangle, firstBlockId: "b2"),
        ]
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [mark("m1", termId: "t1")])
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, marks: [mark("m2", termId: "t2")])

        let result = GlossaryBuilder.build(analysis: analysis, blockOrder: ["b1", "b2"])
        #expect(result.map(\.termId) == ["t2", "t1"])
    }

    @Test("capped at 60 entries")
    func cappedAt60() {
        var analysis = AnalysisRecord()
        var marks: [Mark] = []
        for i in 1 ... 80 {
            let termId = "t\(i)"
            analysis.terms[termId] = TermRecord(term: "Termine \(i)", type: .rectangle, firstBlockId: "b1")
            marks.append(mark("m\(i)", termId: termId))
        }
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: marks)

        let result = GlossaryBuilder.build(analysis: analysis, blockOrder: ["b1"])
        #expect(result.count == 60)
    }

    @Test("a term with no real marks is still included, at the end")
    func termWithoutMarksStillIncluded() {
        var analysis = AnalysisRecord()
        analysis.terms = ["t1": TermRecord(term: "Mai usato", type: .rectangle, firstBlockId: "b1")]
        let result = GlossaryBuilder.build(analysis: analysis, blockOrder: [])
        #expect(result.map(\.termId) == ["t1"])
    }

    @Test("empty glossary returns an empty array")
    func emptyGlossary() {
        #expect(GlossaryBuilder.build(analysis: AnalysisRecord(), blockOrder: []).isEmpty)
    }
}
