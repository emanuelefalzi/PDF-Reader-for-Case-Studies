import Foundation

/// The only data needed to build the map, captured on the MainActor and
/// then processed off the UI thread.
struct MapGraphRequest: Sendable {
    var analysis: AnalysisRecord
    var textBlocks: [TextBlock]
    var blockSnapshots: [MapBlockSnapshot]
    var toc: [MapTocSnapshot]
    var pageCount: Int
    var currentPage: Int
    var scope: MapScope
}

struct MapScene: Sendable, Equatable {
    var fullGraph: ConceptMapGraph
    var displayedGraph: ConceptMapGraph
    var layout: ConceptMapLayout
}

@MainActor
enum MapGraphSource {
    static func capture(from model: DocumentModel, scope: MapScope) -> MapGraphRequest {
        let context = model.analysisController.context
        let analysis = context?.analysis ?? model.analysis ?? AnalysisRecord()
        let textBlocks = context?.blocks ?? []
        let blockSnapshots: [MapBlockSnapshot]
        if !textBlocks.isEmpty {
            blockSnapshots = textBlocks.map {
                MapBlockSnapshot(id: $0.id, pageStart: $0.pageStart, pageEnd: $0.pageEnd)
            }
        } else {
            blockSnapshots = (model.documentRecord?.blocks ?? []).map {
                MapBlockSnapshot(id: $0.id, pageStart: $0.pageStart, pageEnd: $0.pageEnd)
            }
        }
        return MapGraphRequest(
            analysis: analysis,
            textBlocks: textBlocks,
            blockSnapshots: blockSnapshots,
            toc: model.tocEntries.map {
                MapTocSnapshot(id: $0.id, title: $0.title, level: $0.level, page: $0.page)
            },
            pageCount: model.pageCount,
            currentPage: model.currentPageIndex,
            scope: scope
        )
    }
}

enum MapSceneBuilder {
    /// Pure computation. `sidebarLimit == nil` keeps the full graph for the
    /// expanded view; the sidebar starts from the 12 + overflow projection
    /// and, if even so the text would have to shrink below the readable
    /// threshold in the sidebar card, keeps fewer nodes until it fits (SPEC
    /// §5.3 "at most 12 nodes", a ceiling, not a target).
    static func build(_ request: MapGraphRequest, sidebarLimit: Int?) -> MapScene {
        let repetitions = request.textBlocks.isEmpty ? [] : Repetitions.compute(
            blocks: request.textBlocks,
            analysis: request.analysis
        ).map { MapRepetition(blockId: $0.blockId, termId: $0.termId) }
        let input = MapGraphInput(
            analysis: request.analysis,
            blocks: request.blockSnapshots,
            toc: request.toc,
            pageCount: request.pageCount,
            repetitions: repetitions
        )
        let full = MapGraphBuilder.build(input: input, scope: request.scope, currentPage: request.currentPage)
        guard let sidebarLimit else {
            return MapScene(fullGraph: full, displayedGraph: full, layout: MapLayoutEngine.layout(full))
        }

        var limit = sidebarLimit
        var displayed = MapSidebarProjection.project(full, limit: limit)
        var layout = MapLayoutEngine.layout(displayed)
        while limit > MapSidebarProjection.minimumNodeLimit, !MapSidebarProjection.fitsReadably(layout) {
            limit -= 2
            displayed = MapSidebarProjection.project(full, limit: limit)
            layout = MapLayoutEngine.layout(displayed)
        }
        return MapScene(fullGraph: full, displayedGraph: displayed, layout: layout)
    }
}

struct MapViewRevision: Equatable {
    var data: Int
    var page: Int
    var scope: MapScope
}
