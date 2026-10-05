import Foundation

/// Pure, deterministic layout of the graph (SPEC §7.7). Connected components
/// are laid out from left to right; within each one, the node with the most
/// links is the root and the BFS distances become rows. Four barycenter
/// passes stabilize the row order. The base distances already avoid
/// collisions; a final iterative pass, with a fixed order by id, also
/// resolves any residual overlaps.
enum MapLayoutEngine {
    static let nodePadding = 7.0

    private static let canvasPadding = 34.0
    private static let nodeGap = 30.0
    private static let levelGap = 66.0
    private static let componentGap = 54.0
    private static let groupPadding = 28.0
    private static let groupTitleHeight = 24.0
    private static let groupGap = 32.0

    private struct LocalLayout {
        var frames: [MapNodeFrame]
        var size: MapSize
    }

    static func layout(_ graph: ConceptMapGraph) -> ConceptMapLayout {
        guard !graph.nodes.isEmpty else { return .empty }
        if graph.scope == .book, !graph.groups.isEmpty {
            return layoutBook(graph)
        }
        let local = layoutNodes(graph.nodes, edges: graph.edges)
        let shifted = local.frames.map {
            MapNodeFrame(nodeID: $0.nodeID, rect: $0.rect.offsetBy(dx: canvasPadding, dy: canvasPadding))
        }
        let resolved = resolveOverlaps(shifted)
        return ConceptMapLayout(
            nodeFrames: resolved,
            groupFrames: [],
            edgeLabelFrames: MapEdgeLabelLayout.layout(edges: graph.edges, nodeFrames: resolved),
            contentSize: MapSize(
                width: max(1, local.size.width + canvasPadding * 2),
                height: max(1, local.size.height + canvasPadding * 2)
            )
        )
    }

    /// Size of a node measured with the same font/wrapping as the drawing
    /// (`MapTextMetrics`/`MapLabelWrapping`), no longer an estimate by
    /// character count, which underestimated wide letters and made the text
    /// overflow the node.
    static func nodeSize(for label: String) -> MapSize {
        let lines = MapLabelWrapping.lines(for: label)
        let maxLineWidth = lines.map { MapTextMetrics.width(of: $0, font: MapTextMetrics.nodeFont) }.max() ?? 0
        let width = min(174, max(88, maxLineWidth + 30))
        let lineHeight = MapTextMetrics.lineHeight(font: MapTextMetrics.nodeFont)
        let height = max(38, 20 + Double(lines.count) * lineHeight)
        return MapSize(width: width, height: height)
    }

    private static func layoutBook(_ graph: ConceptMapGraph) -> ConceptMapLayout {
        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        var groupLayouts: [(group: MapGroup, layout: LocalLayout, size: MapSize)] = []
        for group in graph.groups.sorted(by: groupOrder) {
            let ids = Set(group.nodeIDs)
            let nodes = group.nodeIDs.compactMap { nodesByID[$0] }
            guard !nodes.isEmpty else { continue }
            let edges = graph.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
            let local = layoutNodes(nodes, edges: edges)
            groupLayouts.append((
                group,
                local,
                MapSize(
                    width: local.size.width + groupPadding * 2,
                    height: local.size.height + groupPadding * 2 + groupTitleHeight
                )
            ))
        }

        let totalArea = groupLayouts.reduce(0) { $0 + $1.size.width * $1.size.height }
        let shelfLimit = max(760, sqrt(totalArea) * 1.45)
        var cursorX = canvasPadding
        var cursorY = canvasPadding
        var rowHeight = 0.0
        var maximumX = 0.0
        var nodeFrames: [MapNodeFrame] = []
        var groupFrames: [MapGroupFrame] = []

        for item in groupLayouts {
            if cursorX > canvasPadding, cursorX + item.size.width > shelfLimit {
                cursorX = canvasPadding
                cursorY += rowHeight + groupGap
                rowHeight = 0
            }
            let groupRect = MapRect(x: cursorX, y: cursorY, width: item.size.width, height: item.size.height)
            groupFrames.append(MapGroupFrame(groupID: item.group.id, title: item.group.title, rect: groupRect))
            let dx = cursorX + groupPadding
            let dy = cursorY + groupPadding + groupTitleHeight
            nodeFrames.append(contentsOf: item.layout.frames.map {
                MapNodeFrame(nodeID: $0.nodeID, rect: $0.rect.offsetBy(dx: dx, dy: dy))
            })
            cursorX += item.size.width + groupGap
            rowHeight = max(rowHeight, item.size.height)
            maximumX = max(maximumX, groupRect.maxX)
        }

        let resolved = resolveOverlaps(nodeFrames)
        let maximumY = groupFrames.map(\.rect.maxY).max() ?? 0
        return ConceptMapLayout(
            nodeFrames: resolved,
            groupFrames: groupFrames,
            edgeLabelFrames: MapEdgeLabelLayout.layout(
                edges: graph.edges,
                nodeFrames: resolved,
                additionalObstacles: groupFrames.map(groupHeaderRect)
            ),
            contentSize: MapSize(width: maximumX + canvasPadding, height: maximumY + canvasPadding)
        )
    }

    /// Band occupied by a group's title in the book map. The edge labels must
    /// also avoid it: checking only the node rectangles still allowed
    /// covering the chapter name.
    static func groupHeaderRect(_ frame: MapGroupFrame) -> MapRect {
        MapRect(
            x: frame.rect.x,
            y: frame.rect.y,
            width: frame.rect.width,
            height: groupPadding + groupTitleHeight
        )
    }

    private static func layoutNodes(_ nodes: [MapNode], edges: [MapEdge]) -> LocalLayout {
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let adjacency = MapLayoutGraphAlgorithms.makeAdjacency(nodeIDs: Set(nodesByID.keys), edges: edges)
        let components = MapLayoutGraphAlgorithms.connectedComponents(nodeIDs: Set(nodesByID.keys), adjacency: adjacency)
            .sorted { MapLayoutGraphAlgorithms.componentOrder($0, $1, nodes: nodesByID, adjacency: adjacency) }

        var cursorX = 0.0
        var maximumHeight = 0.0
        var allFrames: [MapNodeFrame] = []
        for component in components {
            let local = layoutComponent(component, nodes: nodesByID, adjacency: adjacency)
            allFrames.append(contentsOf: local.frames.map {
                MapNodeFrame(nodeID: $0.nodeID, rect: $0.rect.offsetBy(dx: cursorX, dy: 0))
            })
            cursorX += local.size.width + componentGap
            maximumHeight = max(maximumHeight, local.size.height)
        }
        return LocalLayout(
            frames: allFrames,
            size: MapSize(width: max(1, cursorX - componentGap), height: max(1, maximumHeight))
        )
    }

    private static func layoutComponent(
        _ component: [String], nodes: [String: MapNode], adjacency: [String: Set<String>]
    ) -> LocalLayout {
        let componentSet = Set(component)
        let center = component.sorted {
            MapLayoutGraphAlgorithms.nodePriority($0, $1, nodes: nodes, adjacency: adjacency, within: componentSet)
        }.first ?? component[0]
        let distances = MapLayoutGraphAlgorithms.breadthFirstDistances(from: center, allowed: componentSet, adjacency: adjacency)
        let maximumLevel = distances.values.max() ?? 0
        var levels = (0 ... maximumLevel).map { level in
            component.filter { distances[$0] == level }.sorted()
        }

        for _ in 0 ..< 4 {
            for level in 1 ..< levels.count {
                let previousPositions = Dictionary(uniqueKeysWithValues: levels[level - 1].enumerated().map { ($1, Double($0)) })
                let oldPositions = Dictionary(uniqueKeysWithValues: levels[level].enumerated().map { ($1, $0) })
                levels[level].sort { lhs, rhs in
                    let left = MapLayoutGraphAlgorithms.barycenter(lhs, neighbours: adjacency[lhs] ?? [], positions: previousPositions)
                    let right = MapLayoutGraphAlgorithms.barycenter(rhs, neighbours: adjacency[rhs] ?? [], positions: previousPositions)
                    if left != right { return left < right }
                    let li = oldPositions[lhs] ?? 0
                    let ri = oldPositions[rhs] ?? 0
                    return li == ri ? lhs < rhs : li < ri
                }
            }
        }

        let rowWidths = levels.map { ids in
            ids.reduce(0) { $0 + nodeSize(for: nodes[$1]?.label ?? $1).width } +
                Double(max(0, ids.count - 1)) * nodeGap
        }
        let componentWidth = rowWidths.max() ?? 1
        var y = 0.0
        var frames: [MapNodeFrame] = []
        for (level, ids) in levels.enumerated() {
            let heights = ids.map { nodeSize(for: nodes[$0]?.label ?? $0).height }
            let rowHeight = heights.max() ?? 1
            var x = (componentWidth - rowWidths[level]) / 2
            for id in ids {
                let size = nodeSize(for: nodes[id]?.label ?? id)
                frames.append(MapNodeFrame(
                    nodeID: id,
                    rect: MapRect(x: x, y: y + (rowHeight - size.height) / 2, width: size.width, height: size.height)
                ))
                x += size.width + nodeGap
            }
            y += rowHeight + levelGap
        }
        return LocalLayout(
            frames: frames,
            size: MapSize(width: componentWidth, height: max(1, y - levelGap))
        )
    }

    private static func resolveOverlaps(_ frames: [MapNodeFrame]) -> [MapNodeFrame] {
        var result = frames.sorted { $0.nodeID < $1.nodeID }
        for _ in 0 ..< 16 {
            var changed = false
            for leftIndex in result.indices {
                for rightIndex in result.indices where rightIndex > leftIndex {
                    let left = result[leftIndex].rect.insetBy(dx: -nodePadding, dy: -nodePadding)
                    let right = result[rightIndex].rect.insetBy(dx: -nodePadding, dy: -nodePadding)
                    guard left.intersects(right) else { continue }
                    let overlapX = min(left.maxX, right.maxX) - max(left.minX, right.minX)
                    let overlapY = min(left.maxY, right.maxY) - max(left.minY, right.minY)
                    if overlapX <= overlapY {
                        result[rightIndex].rect = result[rightIndex].rect.offsetBy(dx: overlapX + 1, dy: 0)
                    } else {
                        result[rightIndex].rect = result[rightIndex].rect.offsetBy(dx: 0, dy: overlapY + 1)
                    }
                    changed = true
                }
            }
            if !changed { break }
        }
        return result.sorted { $0.nodeID < $1.nodeID }
    }

    private static func groupOrder(_ lhs: MapGroup, _ rhs: MapGroup) -> Bool {
        lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
    }
}
