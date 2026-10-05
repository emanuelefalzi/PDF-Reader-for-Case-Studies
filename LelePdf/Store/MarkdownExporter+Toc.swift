import Foundation

/// Export with a contents outline (M7-7): an extension kept separate from
/// `MarkdownExporter.swift` to keep files at or under ~12 KB. Used when
/// `document.toc.entries` (visible ones) is not empty; see
/// `MarkdownExporter.render`.
extension MarkdownExporter {
    enum TocOrderedItem {
        case heading(TocEntryRecord)
        case block(BlockRecord)
        case exhibit(ExhibitRecord)

        var page: Int {
            switch self {
            case let .heading(entry): entry.page
            case let .block(block): block.pageStart
            case let .exhibit(exhibit): exhibit.page
            }
        }

        /// On the same page: headings first, then blocks, then Exhibits
        /// (the same convention as `AnalysisController.documentOrderSegments`).
        var priority: Int {
            switch self {
            case .heading: 0
            case .block: 1
            case .exhibit: 2
            }
        }
    }

    static func tocOrderedItems(document: DocumentRecord, tocEntries: [TocEntryRecord]) -> [TocOrderedItem] {
        let items: [TocOrderedItem] = ManualToc.sorted(tocEntries).map(TocOrderedItem.heading)
            + document.blocks.map(TocOrderedItem.block) + document.exhibits.map(TocOrderedItem.exhibit)
        return items.enumerated().sorted { lhs, rhs in
            if lhs.element.page != rhs.element.page { return lhs.element.page < rhs.element.page }
            if lhs.element.priority != rhs.element.priority { return lhs.element.priority < rhs.element.priority }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// T1 `##`, T2 `###`, T3 `####`, T4 `#####`.
    static func headingPrefix(level: Int) -> String {
        String(repeating: "#", count: min(max(level + 1, 2), 6))
    }

    /// [M7b, SPEC §5.13 "Export"]: `annotations` interleaved as
    /// "Annotations · p. N" sections at the end of each chapter (T1
    /// heading); see `AnnotationFlusher` in `MarkdownExporter.swift`.
    static func renderWithToc(document: DocumentRecord, analysis: AnalysisRecord, tocEntries: [TocEntryRecord], annotations: AnnotationsRecord) -> String {
        // Block titles sit one level below the deepest level in use.
        let deepestLevel = tocEntries.map(\.level).max() ?? 1
        let blockPrefix = String(repeating: "#", count: min(deepestLevel + 2, 6))
        var flusher = AnnotationFlusher(annotations, headingPrefix: blockPrefix)

        var out = ""
        for item in tocOrderedItems(document: document, tocEntries: tocEntries) {
            switch item {
            case let .heading(entry):
                if entry.level == 1 { out += flusher.flush(before: entry.page) }
                out += "\n\(headingPrefix(level: entry.level)) \(entry.title)\n"
            case let .block(block):
                guard let blockAnalysis = analysis.blocks[block.id], blockAnalysis.status == .analyzed else { continue }
                out += "\n\(blockPrefix) \(blockAnalysis.title ?? "Block") · p. \(block.pageStart + 1)\n\n"
                for rewriteItem in blockAnalysis.rewrite { out += renderRewriteItem(rewriteItem, marks: blockAnalysis.marks) }
                out += obsidianComment(blockId: block.id, marks: blockAnalysis.marks, terms: analysis.terms)
            case let .exhibit(exhibit):
                out += "\n*\(exhibit.label), p. \(exhibit.page + 1)*\n"
            }
        }
        out += flusher.flush(before: nil)
        return out
    }
}
