import Foundation
import Testing
@testable import LelePdf

/// Concept graph data for M8 (SPEC §7.7, M7 brief "manual marks feed the
/// maps: only data now, M8 draws"): nodes (rectangle/circle, not hidden) and
/// links (Claude + manual), aggregated over the whole document.
@Suite("MapDataExtractor")
struct MapDataExtractorTests {
    private func mark(_ id: String, termId: String, type: MarkType, hidden: Bool = false) -> Mark {
        Mark(id: id, termId: termId, type: type, text: "x", source: .claude, page: 0, range: MarkRange(start: 0, length: 1), hidden: hidden)
    }

    @Test("nodes: only rectangle/circle, one per termId, weighted by occurrences")
    func nodesWeightedByOccurrence() {
        let blocks: [String: BlockAnalysis] = [
            "b1": BlockAnalysis(status: .analyzed, marks: [mark("m1", termId: "t1", type: .rectangle), mark("m2", termId: "t2", type: .underline)]),
            "b2": BlockAnalysis(status: .analyzed, marks: [mark("m3", termId: "t1", type: .rectangle)]),
        ]
        let terms = ["t1": TermRecord(term: "Concetto", type: .rectangle, firstBlockId: "b1"), "t2": TermRecord(term: "Azione", type: .underline, firstBlockId: "b1")]
        let graph = MapDataExtractor.extract(from: AnalysisRecord(blocks: blocks, terms: terms))

        #expect(graph.nodes.count == 1) // t2 is an underline, not a node.
        #expect(graph.nodes.first?.termId == "t1")
        #expect(graph.nodes.first?.occurrenceCount == 2)
    }

    @Test("a manual rectangle/circle mark becomes a node just like a Claude one")
    func manualMarkBecomesNode() {
        let manualMark = Mark(id: "m1", termId: "t1", type: .circle, text: "x", source: .manual, page: 0, range: MarkRange(start: 0, length: 1))
        let terms = ["t1": TermRecord(term: "Attore", type: .circle, firstBlockId: "b1")]
        let graph = MapDataExtractor.extract(from: AnalysisRecord(blocks: ["b1": BlockAnalysis(status: .analyzed, marks: [manualMark])], terms: terms))
        #expect(graph.nodes.map(\.termId) == ["t1"])
    }

    @Test("a hidden mark counts neither as a node nor as an occurrence")
    func hiddenMarkExcluded() {
        let terms = ["t1": TermRecord(term: "Concetto", type: .rectangle, firstBlockId: "b1")]
        let blocks = ["b1": BlockAnalysis(status: .analyzed, marks: [mark("m1", termId: "t1", type: .rectangle, hidden: true)])]
        let graph = MapDataExtractor.extract(from: AnalysisRecord(blocks: blocks, terms: terms))
        #expect(graph.nodes.isEmpty)
    }

    @Test("links: only those whose two ends both have a visible node")
    func edgesRequireBothNodesVisible() {
        let terms = ["t1": TermRecord(term: "A", type: .rectangle, firstBlockId: "b1"), "t2": TermRecord(term: "B", type: .circle, firstBlockId: "b1")]
        let validLink = Link(id: "l1", from: "t1", to: "t2", label: "azione", kind: .action, source: .claude)
        let danglingLink = Link(id: "l2", from: "t1", to: "t9", label: "azione", kind: .action, source: .manual)
        let blocks = ["b1": BlockAnalysis(status: .analyzed, marks: [mark("m1", termId: "t1", type: .rectangle), mark("m2", termId: "t2", type: .circle)], links: [validLink, danglingLink])]
        let graph = MapDataExtractor.extract(from: AnalysisRecord(blocks: blocks, terms: terms))
        #expect(graph.edges.map(\.id) == ["l1"])
    }
}
