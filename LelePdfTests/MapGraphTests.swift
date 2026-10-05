import Foundation
import Testing
@testable import LelePdf

@Suite("MapGraph")
struct MapGraphTests {
    @Test("chapter and book scopes filter nodes and links over the right blocks")
    func chapterVersusBook() throws {
        var analysis = AnalysisRecord()
        analysis.terms = [
            "a": TermRecord(term: "Alfa", type: .rectangle, firstBlockId: "b1"),
            "b": TermRecord(term: "Beta", type: .circle, firstBlockId: "b2"),
        ]
        analysis.blocks = [
            "b1": block(marks: [mark("ma", term: "a", page: 1, type: .rectangle)]),
            "b2": block(
                marks: [mark("mb", term: "b", page: 6, type: .circle)],
                links: [Link(id: "l", from: "a", to: "b", label: "porta a", kind: .effect, source: .claude)]
            ),
        ]
        let input = MapGraphInput(
            analysis: analysis,
            blocks: [snapshot("b1", 1), snapshot("b2", 6)],
            toc: toc,
            pageCount: 10
        )

        let first = MapGraphBuilder.build(input: input, scope: .chapter, currentPage: 2)
        #expect(first.title == "Uno")
        #expect(first.nodes.map(\.id) == ["a"])
        #expect(first.edges.isEmpty)

        let second = MapGraphBuilder.build(input: input, scope: .chapter, currentPage: 7)
        #expect(second.nodes.map(\.id) == ["b"])
        #expect(second.edges.isEmpty)

        let book = MapGraphBuilder.build(input: input, scope: .book, currentPage: 2)
        #expect(Set(book.nodes.map(\.id)) == Set(["a", "b"]))
        #expect(book.edges.count == 1)
        #expect(book.edges[0].kind == .effect)
        #expect(book.edges[0].isCrossChapter)
        #expect(book.groups.count == 2)
    }

    @Test("manual rectangle mark included, hidden Claude mark excluded")
    func manualAndHiddenMarks() throws {
        let manual = mark("manual", term: "manual-term", page: 2, type: .rectangle, source: .manual)
        let hiddenClaude = mark("hidden", term: "hidden-term", page: 2, type: .circle, hidden: true)
        let analysis = AnalysisRecord(
            blocks: ["b": block(marks: [manual, hiddenClaude])],
            terms: [
                "manual-term": TermRecord(term: "Nota manuale", type: .rectangle, firstBlockId: "b"),
                "hidden-term": TermRecord(term: "Nascosto", type: .circle, firstBlockId: "b"),
            ]
        )
        let graph = MapGraphBuilder.build(
            input: MapGraphInput(analysis: analysis, blocks: [snapshot("b", 2)], toc: [], pageCount: 4),
            scope: .book,
            currentPage: 2
        )
        let node = try #require(graph.nodes.first)
        #expect(graph.nodes.count == 1)
        #expect(node.id == "manual-term")
        #expect(node.shape == .rectangle)
        #expect(node.firstOccurrence?.markId == "manual")
    }

    @Test("weight includes marks and repetitions; the shape comes from the first mark")
    func weightAndFirstShape() throws {
        let analysis = AnalysisRecord(
            blocks: [
                "b1": block(marks: [mark("m1", term: "t", page: 1, type: .circle)]),
                "b2": block(marks: [mark("m2", term: "t", page: 2, type: .rectangle)]),
            ],
            terms: ["t": TermRecord(term: "Termine", type: .rectangle, firstBlockId: "b1")]
        )
        let input = MapGraphInput(
            analysis: analysis,
            blocks: [snapshot("b1", 1), snapshot("b2", 2)],
            toc: [],
            pageCount: 4,
            repetitions: [MapRepetition(blockId: "b2", termId: "t")]
        )
        let node = try #require(MapGraphBuilder.build(input: input, scope: .book, currentPage: 0).nodes.first)
        #expect(node.weight == 3)
        #expect(node.shape == .ellipse)
    }

    @Test("first occurrence follows the position in the text, not the JSON order")
    func firstOccurrenceUsesDocumentPosition() throws {
        let analysis = AnalysisRecord(
            blocks: [
                "b": block(marks: [
                    mark("dopo", term: "t", page: 1, type: .rectangle, start: 30),
                    mark("prima", term: "t", page: 1, type: .circle, start: 4),
                ]),
            ],
            terms: ["t": TermRecord(term: "Termine", type: .rectangle, firstBlockId: "b")]
        )
        let graph = MapGraphBuilder.build(
            input: MapGraphInput(analysis: analysis, blocks: [snapshot("b", 1)], toc: [], pageCount: 2),
            scope: .book,
            currentPage: 1
        )
        let node = try #require(graph.nodes.first)
        #expect(node.firstOccurrence?.markId == "prima")
        #expect(node.shape == .ellipse)
    }

    @Test("without a table of contents the chapter map covers the whole document")
    func noTocMeansWholeDocument() {
        let analysis = AnalysisRecord(
            blocks: [
                "b1": block(marks: [mark("m1", term: "a", page: 0)]),
                "b2": block(marks: [mark("m2", term: "b", page: 8)]),
            ],
            terms: [
                "a": TermRecord(term: "A", type: .rectangle, firstBlockId: "b1"),
                "b": TermRecord(term: "B", type: .rectangle, firstBlockId: "b2"),
            ]
        )
        let graph = MapGraphBuilder.build(
            input: MapGraphInput(
                analysis: analysis,
                blocks: [snapshot("b1", 0), snapshot("b2", 8)],
                toc: [],
                pageCount: 10
            ),
            scope: .chapter,
            currentPage: 4
        )
        #expect(Set(graph.nodes.map(\.id)) == Set(["a", "b"]))
        #expect(graph.title == "Document")
    }

    @Test("parallel links deduplicated, labels merged, and the manual source preserved")
    func parallelLinks() throws {
        let links = [
            Link(id: "l1", from: "a", to: "b", label: "decide", kind: .action, source: .claude),
            Link(id: "l2", from: "a", to: "b", label: "approva", kind: .action, source: .manual),
        ]
        let analysis = AnalysisRecord(
            blocks: ["b": block(marks: [mark("a", term: "a", page: 0), mark("b", term: "b", page: 0)], links: links)],
            terms: [
                "a": TermRecord(term: "A", type: .rectangle, firstBlockId: "b"),
                "b": TermRecord(term: "B", type: .rectangle, firstBlockId: "b"),
            ]
        )
        let graph = MapGraphBuilder.build(
            input: MapGraphInput(analysis: analysis, blocks: [snapshot("b", 0)], toc: [], pageCount: 1),
            scope: .book,
            currentPage: 0
        )
        let edge = try #require(graph.edges.first)
        #expect(graph.edges.count == 1)
        #expect(edge.label == "approva · decide")
        #expect(edge.source == .manual)
    }

    @Test("book scope keeps the top 40 plus both ends of cross-chapter links")
    func topFortyPlusCrossChapter() {
        var analysis = AnalysisRecord()
        var firstMarks: [Mark] = []
        for index in 0 ..< 44 {
            let id = String(format: "t%02d", index)
            analysis.terms[id] = TermRecord(term: id, type: .rectangle, firstBlockId: "b1")
            firstMarks.append(mark("m\(index)", term: id, page: 1))
        }
        analysis.terms["t44"] = TermRecord(term: "t44", type: .rectangle, firstBlockId: "b2")
        analysis.blocks["b1"] = block(
            marks: firstMarks,
            links: [Link(id: "cross", from: "t43", to: "t44", label: "oltre", kind: .action, source: .manual)]
        )
        analysis.blocks["b2"] = block(marks: [mark("m44", term: "t44", page: 6)])
        let graph = MapGraphBuilder.build(
            input: MapGraphInput(
                analysis: analysis,
                blocks: [snapshot("b1", 1), snapshot("b2", 6)],
                toc: toc,
                pageCount: 10
            ),
            scope: .book,
            currentPage: 1
        )
        #expect(graph.nodes.count == 42)
        #expect(graph.nodes.contains { $0.id == "t43" })
        #expect(graph.nodes.contains { $0.id == "t44" })
        #expect(!graph.nodes.contains { $0.id == "t40" })
    }

    @Test("sidebar caps at 12 nodes and adds +N nodes")
    func sidebarProjection() throws {
        let nodes = (0 ..< 18).map { index in
            MapNode(
                id: "n\(index)", label: "Nodo \(index)", shape: .rectangle, weight: 18 - index,
                firstOccurrence: nil, chapterIDs: ["c"], primaryChapterID: "c"
            )
        }
        let graph = ConceptMapGraph(scope: .chapter, title: "C", nodes: nodes, edges: [], groups: [])
        let projected = MapSidebarProjection.project(graph)
        #expect(projected.nodes.count == 13)
        let overflow = try #require(projected.nodes.last)
        #expect(overflow.isOverflow)
        #expect(overflow.label == "+6 nodes")
    }

    @Test("hit testing returns the topmost node and nil outside")
    func hitTesting() {
        let layout = ConceptMapLayout(
            nodeFrames: [
                MapNodeFrame(nodeID: "a", rect: MapRect(x: 0, y: 0, width: 20, height: 20)),
                MapNodeFrame(nodeID: "b", rect: MapRect(x: 10, y: 10, width: 20, height: 20)),
            ],
            groupFrames: [],
            contentSize: MapSize(width: 30, height: 30)
        )
        #expect(MapHitTesting.node(at: MapPoint(x: 15, y: 15), in: layout) == "b")
        #expect(MapHitTesting.node(at: MapPoint(x: 40, y: 40), in: layout) == nil)
    }

    private var toc: [MapTocSnapshot] {
        [
            MapTocSnapshot(id: "one", title: "Uno", level: 1, page: 0),
            MapTocSnapshot(id: "two", title: "Due", level: 1, page: 5),
        ]
    }

    private func snapshot(_ id: String, _ page: Int) -> MapBlockSnapshot {
        MapBlockSnapshot(id: id, pageStart: page, pageEnd: page)
    }

    private func mark(
        _ id: String, term: String, page: Int, type: MarkType = .rectangle,
        source: MarkSource = .claude, hidden: Bool = false, start: Int = 0
    ) -> Mark {
        Mark(
            id: id, termId: term, type: type, text: term,
            source: source, page: page, range: MarkRange(start: start, length: max(1, term.count)), hidden: hidden
        )
    }

    private func block(marks: [Mark], links: [Link] = []) -> BlockAnalysis {
        BlockAnalysis(status: .analyzed, marks: marks, links: links)
    }
}
