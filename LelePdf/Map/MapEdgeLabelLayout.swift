import Foundation

/// Layout of link labels (SPEC §7.7), separate from node placement: it runs
/// after the nodes are final, uses the same text metrics as the drawing
/// (`MapTextMetrics`) and never overlaps a label with a node or another
/// label. A label that finds no room near its own edge stays hidden (the
/// line/arrow is still visible) instead of overlapping. This closed a gap
/// found in the cross-review ("the background width is limited but the text
/// is not explicitly wrapped or truncated").
enum MapEdgeLabelLayout {
    static let height = 18.0
    static let maxWidth = 128.0
    private static let minWidth = 36.0
    private static let horizontalPadding = 10.0
    private static let obstacleInset = -4.0
    /// Candidate positions along the segment, from the center toward the
    /// ends: prefers the edge's center but slides when it is occupied.
    private static let candidateFractions: [Double] = [0.5, 0.38, 0.62, 0.25, 0.75, 0.15, 0.85]

    static func layout(
        edges: [MapEdge],
        nodeFrames: [MapNodeFrame],
        additionalObstacles: [MapRect] = []
    ) -> [MapEdgeLabelFrame] {
        let framesByID = Dictionary(uniqueKeysWithValues: nodeFrames.map { ($0.nodeID, $0.rect) })
        var obstacles = nodeFrames.map { $0.rect.insetBy(dx: obstacleInset, dy: obstacleInset) }
        obstacles.append(contentsOf: additionalObstacles)
        var placed: [MapEdgeLabelFrame] = []

        for edge in edges.sorted(by: { $0.id < $1.id }) where !edge.label.isEmpty {
            guard let sourceRect = framesByID[edge.from], let targetRect = framesByID[edge.to] else { continue }
            let start = MapGeometry.boundaryPoint(of: sourceRect, toward: targetRect.center)
            let end = MapGeometry.boundaryPoint(of: targetRect, toward: sourceRect.center)
            let text = MapTextMetrics.truncate(edge.label, font: MapTextMetrics.edgeFont, maxWidth: maxWidth - horizontalPadding)
            let width = min(maxWidth, max(minWidth, MapTextMetrics.width(of: text, font: MapTextMetrics.edgeFont) + horizontalPadding))
            guard let rect = firstFittingRect(start: start, end: end, width: width, obstacles: obstacles, placed: placed) else { continue }
            placed.append(MapEdgeLabelFrame(edgeID: edge.id, rect: rect, text: text))
            obstacles.append(rect)
        }
        return placed
    }

    private static func firstFittingRect(
        start: MapPoint, end: MapPoint, width: Double, obstacles: [MapRect], placed: [MapEdgeLabelFrame]
    ) -> MapRect? {
        for fraction in candidateFractions {
            let cx = start.x + (end.x - start.x) * fraction
            let cy = start.y + (end.y - start.y) * fraction
            let candidate = MapRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
            if obstacles.contains(where: { candidate.intersects($0) }) { continue }
            if placed.contains(where: { candidate.intersects($0.rect) }) { continue }
            return candidate
        }
        return nil
    }
}
