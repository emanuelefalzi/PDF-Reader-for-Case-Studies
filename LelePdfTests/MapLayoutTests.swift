import Foundation
import Testing
@testable import LelePdf

@Suite("MapLayout")
struct MapLayoutTests {
    @Test("no overlaps for dense, sparse, and disconnected graphs from 1 to 80 nodes")
    func noOverlapsSynthetic() {
        for count in [1, 5, 12, 40, 80] {
            for kind in GraphKind.allCases {
                let graph = makeGraph(count: count, kind: kind)
                let layout = MapLayoutEngine.layout(graph)
                expectNoOverlap(layout, context: "\(count)-\(kind)")
                #expect(layout.nodeFrames.count == count)
            }
        }
    }

    @Test("the same graph produces a byte-for-byte identical layout")
    func deterministic() {
        let graph = makeGraph(count: 80, kind: .disconnected)
        #expect(MapLayoutEngine.layout(graph) == MapLayoutEngine.layout(graph))
    }

    @Test("the central node is the one with the most links")
    func highestDegreeIsFirstLevel() throws {
        let graph = makeGraph(count: 7, kind: .star)
        let layout = MapLayoutEngine.layout(graph)
        let center = try #require(layout.frame(for: "n00"))
        let otherMinY = try #require(layout.nodeFrames.filter { $0.nodeID != "n00" }.map(\.rect.minY).min())
        #expect(center.minY < otherMinY)
    }

    @Test("book groups and their nodes do not overlap")
    func bookGroupsPackedWithoutOverlap() {
        let graph = makeBookGraph(groups: 6, nodesPerGroup: 9)
        let layout = MapLayoutEngine.layout(graph)
        expectNoOverlap(layout, context: "book")
        for left in layout.groupFrames.indices {
            for right in layout.groupFrames.indices where right > left {
                #expect(!layout.groupFrames[left].rect.intersects(layout.groupFrames[right].rect))
            }
        }
        for label in layout.edgeLabelFrames {
            #expect(layout.groupFrames.allSatisfy {
                !label.rect.intersects(MapLayoutEngine.groupHeaderRect($0))
            })
        }
    }

    @Test("edge labels also avoid obstacles other than nodes")
    func edgeLabelsAvoidAdditionalObstacles() throws {
        let nodes = [
            MapNodeFrame(nodeID: "a", rect: MapRect(x: 0, y: 0, width: 40, height: 40)),
            MapNodeFrame(nodeID: "b", rect: MapRect(x: 300, y: 0, width: 40, height: 40)),
        ]
        let edge = MapEdge(
            id: "e", from: "a", to: "b", label: "collegamento",
            kind: .action, source: .claude, isCrossChapter: false
        )
        let obstacle = MapRect(x: 150, y: 5, width: 40, height: 30)
        let frame = try #require(MapEdgeLabelLayout.layout(
            edges: [edge], nodeFrames: nodes, additionalObstacles: [obstacle]
        ).first)
        #expect(!frame.rect.intersects(obstacle))
    }

    @Test("viewport transform and hit testing stay inverse")
    func viewportInverse() {
        let layout = ConceptMapLayout(
            nodeFrames: [MapNodeFrame(nodeID: "n", rect: MapRect(x: 40, y: 30, width: 100, height: 40))],
            groupFrames: [],
            contentSize: MapSize(width: 200, height: 100)
        )
        let transform = MapCanvasTransform.fitted(
            layout: layout,
            viewport: CGSize(width: 500, height: 300),
            zoom: 1.5,
            pan: CGSize(width: 17, height: -9)
        )
        let map = MapPoint(x: 90, y: 50)
        let viewPoint = CGPoint(
            x: map.x * transform.scale + transform.offset.x,
            y: map.y * transform.scale + transform.offset.y
        )
        let roundTrip = transform.mapPoint(fromView: viewPoint)
        #expect(abs(roundTrip.x - map.x) < 0.000_001)
        #expect(abs(roundTrip.y - map.y) < 0.000_001)
        #expect(MapHitTesting.node(at: roundTrip, in: layout) == "n")
    }

    private enum GraphKind: CaseIterable, CustomStringConvertible {
        case sparse, dense, disconnected, star

        var description: String {
            switch self {
            case .sparse: "sparse"
            case .dense: "dense"
            case .disconnected: "disconnected"
            case .star: "star"
            }
        }
    }

    private func makeGraph(count: Int, kind: GraphKind) -> ConceptMapGraph {
        let nodes = (0 ..< count).map { index in
            MapNode(
                id: String(format: "n%02d", index),
                label: index.isMultiple(of: 3) ? "Nodo con etichetta abbastanza lunga \(index)" : "Nodo \(index)",
                shape: index.isMultiple(of: 2) ? .rectangle : .ellipse,
                weight: count - index,
                firstOccurrence: nil,
                chapterIDs: ["chapter"],
                primaryChapterID: "chapter"
            )
        }
        var pairs = Set<String>()
        func add(_ from: Int, _ to: Int) {
            guard from != to, from < count, to < count else { return }
            let low = min(from, to), high = max(from, to)
            pairs.insert("\(low)|\(high)")
        }
        switch kind {
        case .sparse:
            for index in 1 ..< count { add(index - 1, index) }
        case .dense:
            for left in 0 ..< count {
                for right in (left + 1) ..< min(count, left + 5) { add(left, right) }
            }
        case .disconnected:
            for index in 1 ..< count where !index.isMultiple(of: 4) { add(index - 1, index) }
        case .star:
            for index in 1 ..< count { add(0, index) }
        }
        let edges = pairs.sorted().enumerated().map { index, pair -> MapEdge in
            let bits = pair.split(separator: "|").compactMap { Int($0) }
            return MapEdge(
                id: "e\(index)",
                from: String(format: "n%02d", bits[0]),
                to: String(format: "n%02d", bits[1]),
                label: "lega",
                kind: index.isMultiple(of: 2) ? .action : .effect,
                source: .claude,
                isCrossChapter: false
            )
        }
        return ConceptMapGraph(scope: .chapter, title: "Test", nodes: nodes, edges: edges, groups: [])
    }

    private func makeBookGraph(groups count: Int, nodesPerGroup: Int) -> ConceptMapGraph {
        var nodes: [MapNode] = []
        var edges: [MapEdge] = []
        var groups: [MapGroup] = []
        for groupIndex in 0 ..< count {
            let groupID = "g\(groupIndex)"
            let ids = (0 ..< nodesPerGroup).map { "\(groupID)-n\($0)" }
            nodes.append(contentsOf: ids.enumerated().map { index, id in
                MapNode(
                    id: id, label: "Gruppo \(groupIndex) nodo \(index)", shape: .rectangle,
                    weight: nodesPerGroup - index, firstOccurrence: nil,
                    chapterIDs: [groupID], primaryChapterID: groupID
                )
            })
            for index in 1 ..< ids.count {
                edges.append(MapEdge(
                    id: "\(groupID)-e\(index)", from: ids[0], to: ids[index], label: "lega",
                    kind: .action, source: .claude, isCrossChapter: false
                ))
            }
            groups.append(MapGroup(id: groupID, title: "Capitolo \(groupIndex)", order: groupIndex, nodeIDs: ids))
        }
        return ConceptMapGraph(scope: .book, title: "Libro", nodes: nodes, edges: edges, groups: groups)
    }

    private func expectNoOverlap(_ layout: ConceptMapLayout, context: String) {
        for left in layout.nodeFrames.indices {
            for right in layout.nodeFrames.indices where right > left {
                let a = layout.nodeFrames[left].rect.insetBy(dx: -MapLayoutEngine.nodePadding, dy: -MapLayoutEngine.nodePadding)
                let b = layout.nodeFrames[right].rect.insetBy(dx: -MapLayoutEngine.nodePadding, dy: -MapLayoutEngine.nodePadding)
                #expect(!a.intersects(b), "overlap \(context): \(layout.nodeFrames[left].id) / \(layout.nodeFrames[right].id)")
            }
        }
    }
}
