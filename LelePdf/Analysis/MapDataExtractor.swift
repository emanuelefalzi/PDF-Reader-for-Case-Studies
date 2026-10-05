import Foundation

/// Concept graph data (SPEC §7.7), ready for the map: nodes (terms with a
/// rectangle/circle mark, not hidden) and links, aggregated over the whole
/// document. This type only owns the data (SPEC §7.7 first point: manual
/// marks feed the maps); layout and drawing belong to the map UI. Pure: no
/// dependency on PDFKit/Store, only an `AnalysisRecord` already in memory.
enum MapDataExtractor {
    struct Node: Sendable, Equatable, Identifiable {
        var id: String { termId }
        var termId: String
        var term: String
        var type: MarkType
        /// SPEC §7.7 "a node's weight is its number of occurrences": non-hidden
        /// marks with this `termId`, from any source.
        var occurrenceCount: Int
        var firstBlockId: String
    }

    struct Edge: Sendable, Equatable, Identifiable {
        var id: String
        var from: String
        var to: String
        var label: String
        var kind: LinkKind
        var source: MarkSource
    }

    struct Graph: Sendable, Equatable {
        var nodes: [Node]
        var edges: [Edge]
    }

    static func extract(from analysis: AnalysisRecord) -> Graph {
        var occurrences: [String: Int] = [:]
        var firstBlock: [String: String] = [:]
        for (blockId, blockAnalysis) in analysis.blocks {
            for mark in blockAnalysis.marks where !mark.hidden && (mark.type == .rectangle || mark.type == .circle) {
                occurrences[mark.termId, default: 0] += 1
                if firstBlock[mark.termId] == nil { firstBlock[mark.termId] = blockId }
            }
        }
        let nodes = occurrences.compactMap { termId, count -> Node? in
            guard let term = analysis.terms[termId] else { return nil }
            let origin = term.firstBlockId.isEmpty ? (firstBlock[termId] ?? "") : term.firstBlockId
            return Node(termId: termId, term: term.term, type: term.type, occurrenceCount: count, firstBlockId: origin)
        }.sorted { $0.termId < $1.termId }

        // SPEC §7.7 "Links: from [Claude's] links and from manual marks":
        // `Link.from`/`to` are always termIds (never a raw mark id, see
        // `AnalysisPostProcessor.resolveLinkEndpoint` and
        // `ManualLinkDerivation`). An endpoint pointing to a term with no
        // visible node (rectangle/circle) is discarded, since it cannot be
        // drawn on a node map.
        let nodeIds = Set(nodes.map(\.termId))
        var edges: [Edge] = []
        for blockAnalysis in analysis.blocks.values {
            for link in blockAnalysis.links where nodeIds.contains(link.from) && nodeIds.contains(link.to) {
                edges.append(Edge(id: link.id, from: link.from, to: link.to, label: link.label, kind: link.kind, source: link.source))
            }
        }
        return Graph(nodes: nodes, edges: edges)
    }
}
