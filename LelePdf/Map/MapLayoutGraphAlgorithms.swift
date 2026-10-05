import Foundation

/// Discrete layout operations kept apart from the geometry to keep source
/// files small. All orderings have a lexicographic tie-break.
enum MapLayoutGraphAlgorithms {
    static func makeAdjacency(nodeIDs: Set<String>, edges: [MapEdge]) -> [String: Set<String>] {
        var result = Dictionary(uniqueKeysWithValues: nodeIDs.map { ($0, Set<String>()) })
        for edge in edges where nodeIDs.contains(edge.from) && nodeIDs.contains(edge.to) && edge.from != edge.to {
            result[edge.from, default: []].insert(edge.to)
            result[edge.to, default: []].insert(edge.from)
        }
        return result
    }

    static func connectedComponents(
        nodeIDs: Set<String>, adjacency: [String: Set<String>]
    ) -> [[String]] {
        var remaining = nodeIDs
        var result: [[String]] = []
        while let start = remaining.sorted().first {
            var queue = [start]
            var seen = Set([start])
            remaining.remove(start)
            var offset = 0
            while offset < queue.count {
                let id = queue[offset]
                offset += 1
                for neighbour in (adjacency[id] ?? []).sorted() where remaining.contains(neighbour) {
                    remaining.remove(neighbour)
                    seen.insert(neighbour)
                    queue.append(neighbour)
                }
            }
            result.append(seen.sorted())
        }
        return result
    }

    static func breadthFirstDistances(
        from start: String, allowed: Set<String>, adjacency: [String: Set<String>]
    ) -> [String: Int] {
        var result = [start: 0]
        var queue = [start]
        var offset = 0
        while offset < queue.count {
            let id = queue[offset]
            offset += 1
            for neighbour in (adjacency[id] ?? []).sorted()
                where allowed.contains(neighbour) && result[neighbour] == nil {
                result[neighbour] = (result[id] ?? 0) + 1
                queue.append(neighbour)
            }
        }
        return result
    }

    static func barycenter(_ id: String, neighbours: Set<String>, positions: [String: Double]) -> Double {
        let values = neighbours.compactMap { positions[$0] }
        guard !values.isEmpty else { return .greatestFiniteMagnitude }
        return values.reduce(0, +) / Double(values.count)
    }

    static func componentOrder(
        _ lhs: [String], _ rhs: [String], nodes: [String: MapNode], adjacency: [String: Set<String>]
    ) -> Bool {
        let leftSet = Set(lhs), rightSet = Set(rhs)
        let left = lhs.sorted { nodePriority($0, $1, nodes: nodes, adjacency: adjacency, within: leftSet) }.first ?? ""
        let right = rhs.sorted { nodePriority($0, $1, nodes: nodes, adjacency: adjacency, within: rightSet) }.first ?? ""
        return nodePriority(left, right, nodes: nodes, adjacency: adjacency, within: Set(lhs + rhs))
    }

    static func nodePriority(
        _ lhs: String,
        _ rhs: String,
        nodes: [String: MapNode],
        adjacency: [String: Set<String>],
        within: Set<String>
    ) -> Bool {
        let leftDegree = (adjacency[lhs] ?? []).intersection(within).count
        let rightDegree = (adjacency[rhs] ?? []).intersection(within).count
        if leftDegree != rightDegree { return leftDegree > rightDegree }
        let leftWeight = nodes[lhs]?.weight ?? 0
        let rightWeight = nodes[rhs]?.weight ?? 0
        return leftWeight == rightWeight ? lhs < rhs : leftWeight > rightWeight
    }
}

/// Wrapping of node labels. Delegates to `MapTextMetrics` (width measured
/// with the real font, not a character count): `MapLayoutEngine` (layout)
/// and `MapCanvasView` (drawing) both call this same function, so the size
/// computed for a node is always the one the `Canvas` actually draws (this
/// was the main cause of the unreadable map; see `MapTextMetrics`).
enum MapLabelWrapping {
    static let maxTextWidth = 144.0
    static let maxLines = 3

    static func wrapped(_ label: String) -> String {
        lines(for: label).joined(separator: "\n")
    }

    static func lines(for label: String) -> [String] {
        MapTextMetrics.wrapLines(label, font: MapTextMetrics.nodeFont, maxWidth: maxTextWidth, maxLines: maxLines)
    }
}
