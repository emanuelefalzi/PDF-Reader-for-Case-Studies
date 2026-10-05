import Foundation

enum MapScope: String, CaseIterable, Sendable {
    case chapter
    case book

    var label: String {
        switch self {
        case .chapter: String(localized: "Chapter")
        case .book: String(localized: "Book")
        }
    }
}

enum MapNodeShape: Sendable, Equatable {
    case rectangle
    case ellipse
}

struct MapBlockSnapshot: Sendable, Equatable {
    var id: String
    var pageStart: Int
    var pageEnd: Int
}

struct MapTocSnapshot: Sendable, Equatable {
    var id: String
    var title: String
    var level: Int
    var page: Int
}

struct MapRepetition: Sendable, Equatable {
    var blockId: String
    var termId: String
}

/// Sendable data needed by the pure function that builds the graph.
/// `AnalysisRecord` remains the source of truth; blocks and contents only
/// serve to establish order and chapter, while repetitions are derived and
/// are not saved (SPEC §7.5.4).
struct MapGraphInput: Sendable, Equatable {
    var analysis: AnalysisRecord
    var blocks: [MapBlockSnapshot]
    var toc: [MapTocSnapshot]
    var pageCount: Int
    var repetitions: [MapRepetition] = []
}

struct MapOccurrence: Sendable, Equatable {
    var blockId: String
    var markId: String
    var page: Int
    var range: MarkRange
}

struct MapNode: Sendable, Equatable, Identifiable {
    static let overflowID = "__lelepdf_more_nodes__"

    var id: String
    var label: String
    var shape: MapNodeShape
    var weight: Int
    var firstOccurrence: MapOccurrence?
    var chapterIDs: [String]
    var primaryChapterID: String
    var isOverflow: Bool = false
}

struct MapEdge: Sendable, Equatable, Identifiable {
    var id: String
    var from: String
    var to: String
    var label: String
    var kind: LinkKind
    var source: MarkSource
    var isCrossChapter: Bool
}

struct MapGroup: Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var order: Int
    var nodeIDs: [String]
}

struct ConceptMapGraph: Sendable, Equatable {
    var scope: MapScope
    var title: String
    var nodes: [MapNode]
    var edges: [MapEdge]
    var groups: [MapGroup]

    static func empty(scope: MapScope, title: String = "") -> ConceptMapGraph {
        ConceptMapGraph(scope: scope, title: title, nodes: [], edges: [], groups: [])
    }
}

struct MapPoint: Sendable, Equatable {
    var x: Double
    var y: Double
}

struct MapSize: Sendable, Equatable {
    var width: Double
    var height: Double
}

struct MapRect: Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var center: MapPoint { MapPoint(x: x + width / 2, y: y + height / 2) }

    func insetBy(dx: Double, dy: Double) -> MapRect {
        MapRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    func intersects(_ other: MapRect) -> Bool {
        minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
    }

    func offsetBy(dx: Double, dy: Double) -> MapRect {
        MapRect(x: x + dx, y: y + dy, width: width, height: height)
    }
}

struct MapNodeFrame: Sendable, Equatable, Identifiable {
    var id: String { nodeID }
    var nodeID: String
    var rect: MapRect
}

struct MapGroupFrame: Sendable, Equatable, Identifiable {
    var id: String { groupID }
    var groupID: String
    var title: String
    var rect: MapRect
}

/// Rectangle of an already-placed link label (SPEC §7.7): only the edges
/// that found room without overlapping a node or another label end up here
/// (`MapEdgeLabelLayout`); the others stay without a drawn label (the
/// line/arrow is still visible) instead of overlapping. This closed a gap
/// found in the map's review ("link labels").
struct MapEdgeLabelFrame: Sendable, Equatable, Identifiable {
    var id: String { edgeID }
    var edgeID: String
    var rect: MapRect
    /// Text already truncated to the measured width: drawing uses it as is,
    /// without re-measuring it with a different heuristic.
    var text: String
}

struct ConceptMapLayout: Sendable, Equatable {
    var nodeFrames: [MapNodeFrame]
    var groupFrames: [MapGroupFrame]
    var edgeLabelFrames: [MapEdgeLabelFrame] = []
    var contentSize: MapSize

    static let empty = ConceptMapLayout(nodeFrames: [], groupFrames: [], contentSize: MapSize(width: 1, height: 1))

    func frame(for nodeID: String) -> MapRect? {
        nodeFrames.first(where: { $0.nodeID == nodeID })?.rect
    }

    func edgeLabelFrame(for edgeID: String) -> MapEdgeLabelFrame? {
        edgeLabelFrames.first(where: { $0.edgeID == edgeID })
    }
}

/// Geometry shared between the layout (`MapLayoutEngine`,
/// `MapEdgeLabelLayout`) and the drawing (`MapCanvasView`): the same
/// boundary point computed once, not two formulas that could drift apart.
enum MapGeometry {
    static func boundaryPoint(of rect: MapRect, toward point: MapPoint) -> MapPoint {
        let center = rect.center
        let dx = point.x - center.x, dy = point.y - center.y
        let scaleX = abs(dx) < 0.001 ? .infinity : rect.width / 2 / abs(dx)
        let scaleY = abs(dy) < 0.001 ? .infinity : rect.height / 2 / abs(dy)
        let scale = min(scaleX, scaleY)
        guard scale.isFinite else { return center }
        return MapPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }
}

enum MapHitTesting {
    static func node(at point: MapPoint, in layout: ConceptMapLayout) -> String? {
        layout.nodeFrames.reversed().first { frame in
            point.x >= frame.rect.minX && point.x <= frame.rect.maxX &&
                point.y >= frame.rect.minY && point.y <= frame.rect.maxY
        }?.nodeID
    }
}
