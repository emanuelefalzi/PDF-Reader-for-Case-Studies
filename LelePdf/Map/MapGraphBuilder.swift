import Foundation

/// Pure construction of the maps from `AnalysisRecord` (SPEC §7.7). It does
/// not depend on `DocumentModel`, PDFKit or the Store actor: so manual
/// marks/links can be added to the record and immediately yield the same
/// graph, with no second intermediate format.
enum MapGraphBuilder {
    static let bookWeightLimit = 40

    private struct Chapter: Sendable {
        var id: String
        var title: String
        var order: Int
        var pages: ClosedRange<Int>
    }

    private struct MarkPlacement {
        var blockId: String
        var mark: Mark
        var chapter: Chapter
        var order: Int
    }

    private struct EdgeKey: Hashable {
        var from: String
        var to: String
        var kind: LinkKind
    }

    private struct RawEdge {
        var link: Link
        var chapterID: String
    }

    static func build(input: MapGraphInput, scope: MapScope, currentPage: Int) -> ConceptMapGraph {
        let chapters = makeChapters(input.toc, pageCount: input.pageCount)
        guard let currentChapter = chapter(at: currentPage, chapters: chapters) else {
            return .empty(scope: scope)
        }
        let blocksByID = Dictionary(uniqueKeysWithValues: input.blocks.map { ($0.id, $0) })
        let blockOrderByID = Dictionary(uniqueKeysWithValues: input.blocks.enumerated().map { ($1.id, $0) })
        let orderedBlockIDs = input.analysis.blocks.keys.sorted { lhs, rhs in
            let lp = blocksByID[lhs]?.pageStart ?? input.analysis.blocks[lhs]?.marks.map(\.page).min() ?? Int.max
            let rp = blocksByID[rhs]?.pageStart ?? input.analysis.blocks[rhs]?.marks.map(\.page).min() ?? Int.max
            if lp != rp { return lp < rp }
            let leftOrder = blockOrderByID[lhs] ?? Int.max
            let rightOrder = blockOrderByID[rhs] ?? Int.max
            return leftOrder == rightOrder ? lhs < rhs : leftOrder < rightOrder
        }

        var placements: [MarkPlacement] = []
        var rawEdges: [RawEdge] = []
        for (blockOrder, blockID) in orderedBlockIDs.enumerated() {
            guard let block = input.analysis.blocks[blockID] else { continue }
            let fallbackPage = blocksByID[blockID]?.pageStart ?? block.marks.map(\.page).min() ?? 0
            let blockChapter = chapter(at: fallbackPage, chapters: chapters) ?? currentChapter
            for mark in block.marks where !mark.hidden {
                let markChapter = chapter(at: mark.page, chapters: chapters) ?? blockChapter
                placements.append(MarkPlacement(blockId: blockID, mark: mark, chapter: markChapter, order: blockOrder))
            }
            let hiddenMarkIDs = Set(block.marks.filter(\.hidden).map(\.id))
            rawEdges.append(contentsOf: block.links.compactMap { link in
                if let via = link.via, hiddenMarkIDs.contains(via) { return nil }
                return RawEdge(link: link, chapterID: blockChapter.id)
            })
        }

        if scope == .chapter {
            placements.removeAll { $0.chapter.id != currentChapter.id }
            rawEdges.removeAll { $0.chapterID != currentChapter.id }
        }

        let repetitions = input.repetitions.filter { repetition in
            guard scope == .chapter else { return true }
            let page = blocksByID[repetition.blockId]?.pageStart ?? -1
            return chapter(at: page, chapters: chapters)?.id == currentChapter.id
        }

        let visiblePlacementsByTerm = Dictionary(grouping: placements, by: { $0.mark.termId })
        let nodePlacementsByTerm = Dictionary(grouping: placements.filter { isMapNodeMark($0.mark) }, by: { $0.mark.termId })
        var nodes: [MapNode] = []
        for termID in nodePlacementsByTerm.keys.sorted() {
            guard var nodePlacements = nodePlacementsByTerm[termID], !nodePlacements.isEmpty else { continue }
            nodePlacements.sort(by: placementOrder)
            let first = nodePlacements[0]
            let visiblePlacements = visiblePlacementsByTerm[termID] ?? nodePlacements
            var chapterIDs = Set(visiblePlacements.map { $0.chapter.id })
            for repetition in repetitions where repetition.termId == termID {
                if let page = blocksByID[repetition.blockId]?.pageStart,
                   let repetitionChapter = chapter(at: page, chapters: chapters) {
                    chapterIDs.insert(repetitionChapter.id)
                }
            }
            let label = input.analysis.terms[termID]?.term.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedLabel = (label?.isEmpty == false ? label! : first.mark.text)
            nodes.append(MapNode(
                id: termID,
                label: resolvedLabel,
                shape: first.mark.type == .circle ? .ellipse : .rectangle,
                weight: visiblePlacements.count + repetitions.count(where: { $0.termId == termID }),
                firstOccurrence: MapOccurrence(
                    blockId: first.blockId, markId: first.mark.id, page: first.mark.page, range: first.mark.range
                ),
                chapterIDs: chapterIDs.sorted(),
                primaryChapterID: first.chapter.id
            ))
        }

        var nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var edges = makeEdges(rawEdges, nodes: nodeByID)

        if scope == .book, nodes.count > bookWeightLimit {
            let ranked = nodes.sorted(by: nodeRank)
            var kept = Set(ranked.prefix(bookWeightLimit).map(\.id))
            for edge in edges where edge.isCrossChapter {
                kept.insert(edge.from)
                kept.insert(edge.to)
            }
            nodes.removeAll { !kept.contains($0.id) }
            nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            edges.removeAll { nodeByID[$0.from] == nil || nodeByID[$0.to] == nil }
        }

        nodes.sort(by: nodeRank)
        let groups: [MapGroup]
        if scope == .book {
            groups = chapters.compactMap { item in
                let ids = nodes.filter { $0.primaryChapterID == item.id }.map(\.id).sorted()
                return ids.isEmpty ? nil : MapGroup(id: item.id, title: item.title, order: item.order, nodeIDs: ids)
            }
        } else {
            groups = []
        }
        let title = scope == .chapter ? currentChapter.title : "Book"
        return ConceptMapGraph(scope: scope, title: title, nodes: nodes, edges: edges, groups: groups)
    }

    private static func isMapNodeMark(_ mark: Mark) -> Bool {
        !mark.hidden && (mark.type == .rectangle || mark.type == .circle)
    }

    private static func makeEdges(_ raw: [RawEdge], nodes: [String: MapNode]) -> [MapEdge] {
        let valid = raw.filter { nodes[$0.link.from] != nil && nodes[$0.link.to] != nil }
        let grouped = Dictionary(grouping: valid) {
            EdgeKey(from: $0.link.from, to: $0.link.to, kind: $0.link.kind)
        }
        return grouped.keys.sorted {
            ($0.from, $0.to, $0.kind.rawValue) < ($1.from, $1.to, $1.kind.rawValue)
        }.compactMap { key in
            guard let parallel = grouped[key], let from = nodes[key.from], let to = nodes[key.to] else { return nil }
            let labels = Array(Set(parallel.map { $0.link.label.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
            let linkChapters = Set(parallel.map(\.chapterID))
            let cross = from.primaryChapterID != to.primaryChapterID ||
                !linkChapters.isSubset(of: Set(from.chapterIDs).intersection(to.chapterIDs))
            return MapEdge(
                id: "\(key.from)|\(key.to)|\(key.kind.rawValue)",
                from: key.from,
                to: key.to,
                label: labels.joined(separator: " · "),
                kind: key.kind,
                source: parallel.contains(where: { $0.link.source == .manual }) ? .manual : .claude,
                isCrossChapter: cross
            )
        }
    }

    private static func nodeRank(_ lhs: MapNode, _ rhs: MapNode) -> Bool {
        lhs.weight == rhs.weight ? lhs.id < rhs.id : lhs.weight > rhs.weight
    }

    /// "First mark" means first position in the document, not accidental
    /// order in the JSON array: page, block, range, id as the last
    /// deterministic tie-break. The node's shape and its navigation both
    /// use this same occurrence (SPEC §5.3/§7.7).
    private static func placementOrder(_ lhs: MarkPlacement, _ rhs: MarkPlacement) -> Bool {
        if lhs.mark.page != rhs.mark.page { return lhs.mark.page < rhs.mark.page }
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        if lhs.mark.range.start != rhs.mark.range.start { return lhs.mark.range.start < rhs.mark.range.start }
        return lhs.mark.id < rhs.mark.id
    }

    private static func makeChapters(_ toc: [MapTocSnapshot], pageCount: Int) -> [Chapter] {
        let lastPage = max(0, pageCount - 1)
        var levelOne = toc.filter { $0.level == 1 && $0.page >= 0 && $0.page <= lastPage }
        levelOne.sort { $0.page == $1.page ? $0.id < $1.id : $0.page < $1.page }
        var unique: [MapTocSnapshot] = []
        for entry in levelOne where unique.last?.page != entry.page { unique.append(entry) }
        guard !unique.isEmpty else {
            return [Chapter(id: "document", title: "Document", order: 0, pages: 0...lastPage)]
        }

        var result: [Chapter] = []
        if let first = unique.first, first.page > 0 {
            result.append(Chapter(id: "preface", title: "Introduction", order: 0, pages: 0...(first.page - 1)))
        }
        for (index, entry) in unique.enumerated() {
            let nextPage = index + 1 < unique.count ? unique[index + 1].page : lastPage + 1
            result.append(Chapter(
                id: "chapter-\(entry.id)", title: entry.title, order: result.count,
                pages: entry.page...max(entry.page, nextPage - 1)
            ))
        }
        return result
    }

    private static func chapter(at page: Int, chapters: [Chapter]) -> Chapter? {
        chapters.last(where: { $0.pages.contains(page) }) ?? chapters.first
    }
}
