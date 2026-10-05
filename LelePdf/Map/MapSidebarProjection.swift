import Foundation

/// Graph projection for the sidebar (SPEC §5.3: "at most 12 nodes, plus a
/// '+N nodes' node"). File separate from `MapGraphBuilder.swift` to stay
/// under ~12 KB.
enum MapSidebarProjection {
    static let nodeLimit = 12
    /// We do not go below this many nodes even if the text would stay small:
    /// better a dense map that is present than one that vanishes entirely.
    static let minimumNodeLimit = 4
    /// Minimum readable scale: below it, the 12 pt font as drawn would become
    /// smaller than ~8.6 pt in the sidebar. Below this threshold fewer nodes
    /// are shown (more "+N nodes") instead of shrinking the text (SPEC §5.3:
    /// "at most 12 nodes").
    static let minimumReadableScale = 0.72
    /// Approximate, conservative inner area of the map card in the sidebar
    /// (`MapSidebarView.mapCard`, height 250-330 pt, sidebar width 264 pt
    /// minus margins): used only to decide how many nodes to keep, not for
    /// the actual drawing (that remains `MapCanvasTransform.fitted`,
    /// computed on the view's real size).
    static let sidebarFitBox = MapSize(width: 208, height: 246)

    /// True if the layout, fitted to `sidebarFitBox`, does not require going
    /// below the readable scale.
    static func fitsReadably(_ layout: ConceptMapLayout) -> Bool {
        guard layout.contentSize.width > 0, layout.contentSize.height > 0 else { return true }
        let scale = min(
            sidebarFitBox.width / layout.contentSize.width,
            sidebarFitBox.height / layout.contentSize.height,
            1
        )
        return scale >= minimumReadableScale
    }

    static func project(_ graph: ConceptMapGraph, limit: Int = nodeLimit) -> ConceptMapGraph {
        guard graph.nodes.count > limit else { return graph }
        let keptNodes = Array(graph.nodes.sorted {
            $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight
        }.prefix(limit))
        let keptIDs = Set(keptNodes.map(\.id))
        let hiddenCount = graph.nodes.count - keptNodes.count
        let overflow = MapNode(
            id: MapNode.overflowID, label: "+\(hiddenCount) nodes", shape: .rectangle,
            weight: 0, firstOccurrence: nil, chapterIDs: [], primaryChapterID: "overflow", isOverflow: true
        )
        var groups = graph.groups.map { group in
            var copy = group
            copy.nodeIDs = group.nodeIDs.filter { keptIDs.contains($0) }
            return copy
        }.filter { !$0.nodeIDs.isEmpty }
        if graph.scope == .book {
            groups.append(MapGroup(id: "overflow", title: "Other", order: Int.max, nodeIDs: [MapNode.overflowID]))
        }
        return ConceptMapGraph(
            scope: graph.scope, title: graph.title, nodes: keptNodes + [overflow],
            edges: graph.edges.filter { keptIDs.contains($0.from) && keptIDs.contains($0.to) }, groups: groups
        )
    }
}
