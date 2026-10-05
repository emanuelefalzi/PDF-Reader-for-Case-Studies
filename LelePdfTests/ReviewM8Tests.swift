import Foundation
import Testing
@testable import LelePdf

@Suite("Review M8 · graph construction")
struct ReviewM8GraphTests {
    private func mark(
        _ id: String, term: String, type: MarkType, page: Int,
        source: MarkSource = .claude, hidden: Bool = false
    ) -> Mark {
        Mark(
            id: id, termId: term, type: type, text: id,
            source: source, page: page, range: MarkRange(start: 0, length: 1), hidden: hidden
        )
    }

    @Test("all hidden marks are excluded, the weight counts every type, and a link via a hidden mark disappears")
    func hiddenMarksWeightsAndLinks() throws {
        let visibleNode = mark("node", term: "t", type: .rectangle, page: 0, source: .manual)
        let visibleAction = mark("action", term: "t", type: .underline, page: 0)
        let otherNode = mark("other", term: "u", type: .circle, page: 0)
        let hiddenManualNode = mark("hidden-manual", term: "h", type: .rectangle, page: 0, source: .manual, hidden: true)
        let hiddenVia = mark("hidden-via", term: "t", type: .arrow, page: 0, hidden: true)
        let links = [
            Link(id: "hidden-edge", from: "t", to: "u", label: "nascosto", kind: .effect, source: .claude, via: "hidden-via"),
            Link(id: "manual-edge", from: "t", to: "u", label: "visibile", kind: .action, source: .manual),
        ]
        let analysis = AnalysisRecord(
            blocks: ["b": BlockAnalysis(status: .analyzed, marks: [visibleNode, visibleAction, otherNode, hiddenManualNode, hiddenVia], links: links)],
            terms: [
                "t": TermRecord(term: "Termine", type: .rectangle, firstBlockId: "b"),
                "u": TermRecord(term: "Altro", type: .circle, firstBlockId: "b"),
                "h": TermRecord(term: "Nascosto", type: .rectangle, firstBlockId: "b"),
            ]
        )
        let graph = MapGraphBuilder.build(
            input: MapGraphInput(
                analysis: analysis,
                blocks: [MapBlockSnapshot(id: "b", pageStart: 0, pageEnd: 0)],
                toc: [], pageCount: 1,
                repetitions: [MapRepetition(blockId: "b", termId: "t")]
            ),
            scope: .book,
            currentPage: 0
        )

        #expect(Set(graph.nodes.map(\.id)) == Set(["t", "u"]))
        #expect(graph.nodes.first(where: { $0.id == "t" })?.weight == 3)
        #expect(graph.edges.count == 1)
        #expect(graph.edges.first?.id == "t|u|action")
        #expect(graph.edges.first?.source == .manual)
    }

    @Test("top 40 with equal weights also keeps the two cross-chapter endpoints")
    func equalWeightsTopFortyPlusCrossChapter() {
        var analysis = AnalysisRecord()
        var firstChapterMarks: [Mark] = []
        for index in 0 ..< 44 {
            let term = String(format: "t%02d", index)
            analysis.terms[term] = TermRecord(term: term, type: .rectangle, firstBlockId: "a")
            firstChapterMarks.append(mark("m\(index)", term: term, type: .rectangle, page: 0))
        }
        analysis.terms["t44"] = TermRecord(term: "t44", type: .rectangle, firstBlockId: "b")
        analysis.blocks["a"] = BlockAnalysis(
            status: .analyzed,
            marks: firstChapterMarks,
            links: [Link(id: "cross", from: "t43", to: "t44", label: "oltre", kind: .effect, source: .manual)]
        )
        analysis.blocks["b"] = BlockAnalysis(status: .analyzed, marks: [mark("m44", term: "t44", type: .rectangle, page: 5)])
        let graph = MapGraphBuilder.build(
            input: MapGraphInput(
                analysis: analysis,
                blocks: [MapBlockSnapshot(id: "a", pageStart: 0, pageEnd: 0), MapBlockSnapshot(id: "b", pageStart: 5, pageEnd: 5)],
                toc: [
                    MapTocSnapshot(id: "c1", title: "Uno", level: 1, page: 0),
                    MapTocSnapshot(id: "c2", title: "Due", level: 1, page: 5),
                ],
                pageCount: 10
            ),
            scope: .book,
            currentPage: 0
        )

        #expect(graph.nodes.count == 42)
        #expect(graph.nodes.contains { $0.id == "t43" })
        #expect(graph.nodes.contains { $0.id == "t44" })
        #expect(!graph.nodes.contains { $0.id == "t42" })
    }

    @Test("sidebar: twelve nodes plus overflow, with hit-testing of the overflow")
    func sidebarProjectionAndHitTesting() throws {
        let nodes = (0 ..< 14).map { index in
            MapNode(
                id: "n\(index)", label: "N\(index)", shape: .rectangle, weight: 1,
                firstOccurrence: nil, chapterIDs: ["c"], primaryChapterID: "c"
            )
        }
        let projected = MapSidebarProjection.project(
            ConceptMapGraph(scope: .chapter, title: "C", nodes: nodes, edges: [], groups: [])
        )
        #expect(projected.nodes.count == 13)
        #expect(projected.nodes.last?.label == "+2 nodes")
        let layout = MapLayoutEngine.layout(projected)
        let overflowFrame = try #require(layout.frame(for: MapNode.overflowID))
        #expect(MapHitTesting.node(at: overflowFrame.center, in: layout) == MapNode.overflowID)
    }
}

@Suite("Review M8 · adversarial layout")
struct ReviewM8LayoutTests {
    @Test("1, 2 and 80 disconnected nodes, equal weights and long labels: deterministic and without overlap")
    func adversarialDisconnectedGraphs() {
        for count in [1, 2, 80] {
            let graph = graph(count: count)
            let first = MapLayoutEngine.layout(graph)
            let second = MapLayoutEngine.layout(graph)
            #expect(first == second)
            #expect(first.nodeFrames.count == count)
            expectNoOverlap(first, label: "\(count) nodes")
        }
    }

    @Test("a very long word is limited to three readable lines")
    func veryLongSingleWordIsWrappedAndTruncated() {
        let lines = MapLabelWrapping.lines(for: String(repeating: "x", count: 400))
        #expect(lines.count == 3)
        // Width measured with the real font (no longer a character count):
        // every line must fit within the node text's maximum width, the same
        // one `nodeSize` uses to size it.
        #expect(lines.allSatisfy { MapTextMetrics.width(of: $0, font: MapTextMetrics.nodeFont) <= MapLabelWrapping.maxTextWidth })
        #expect(lines.last?.hasSuffix("…") == true)
    }

    private func graph(count: Int) -> ConceptMapGraph {
        let nodes = (0 ..< count).map { index in
            MapNode(
                id: String(format: "n%03d", index),
                label: index.isMultiple(of: 2)
                    ? String(repeating: "etichetta", count: 35) + " \(index)"
                    : "Nodo disconnesso \(index)",
                shape: index.isMultiple(of: 2) ? .rectangle : .ellipse,
                weight: 1,
                firstOccurrence: nil,
                chapterIDs: ["chapter"],
                primaryChapterID: "chapter"
            )
        }
        return ConceptMapGraph(scope: .chapter, title: "Avversario", nodes: nodes, edges: [], groups: [])
    }

    private func expectNoOverlap(_ layout: ConceptMapLayout, label: String) {
        for left in layout.nodeFrames.indices {
            for right in layout.nodeFrames.indices where right > left {
                let lhs = layout.nodeFrames[left].rect.insetBy(dx: -MapLayoutEngine.nodePadding, dy: -MapLayoutEngine.nodePadding)
                let rhs = layout.nodeFrames[right].rect.insetBy(dx: -MapLayoutEngine.nodePadding, dy: -MapLayoutEngine.nodePadding)
                #expect(!lhs.intersects(rhs), "overlap \(label): \(layout.nodeFrames[left].id) / \(layout.nodeFrames[right].id)")
            }
        }
    }
}
