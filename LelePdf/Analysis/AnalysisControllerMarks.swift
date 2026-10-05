import Foundation
@preconcurrency import PDFKit

/// A mark (or a repetition occurrence) ready to be drawn in page space (SPEC
/// §5.4, §11; shape: `{markId?, termId, type, isRepetition, hidden,
/// pageRange, lineRects}`). `markId` is `nil` for a repetition (it is not a
/// saved mark in its own right).
struct PageMarkItem: Sendable, Equatable {
    /// Owning block of the real mark. `nil` only for a repetition.
    var blockId: String?
    var markId: String?
    var termId: String
    var type: MarkType
    var isRepetition: Bool
    var hidden: Bool
    var pageIndex: Int
    /// Per-line rectangles in page space (`PDFSelection.selectionsByLine()` +
    /// `bounds(for:)`, SPEC §4/§7.3 last point).
    var lineRects: [PageRect]
}

/// Computation of the mark rectangles per page (MainActor: it uses
/// `BlockSelectionResolver`/`PDFSelection`, which are not `Sendable`).
/// Per-page cache in `AnalysisController.markItemsCache`, invalidated on every
/// `updateContext`/saved analysis: a recompute of the whole page, not a
/// fine-grained invalidation per mark (a reasonably correct whole-page
/// recompute is fine here).
@MainActor
extension AnalysisController {
    func markItems(forPage pageIndex: Int, document: PDFDocument) -> [PageMarkItem] {
        if let cached = markItemsCache[pageIndex] { return cached }
        guard let context else { return [] }
        return PerfProbe.measure("marks.markItems.build") {
            buildMarkItems(forPage: pageIndex, document: document, context: context)
        }
    }

    private func buildMarkItems(forPage pageIndex: Int, document: PDFDocument, context: AnalysisQueue.DocumentContext) -> [PageMarkItem] {
        var items: [PageMarkItem] = []
        let blocksOnPage = context.blocks.filter { $0.pageStart <= pageIndex && pageIndex <= $0.pageEnd }
        for block in blocksOnPage {
            // No `status == .analyzed` check here: a manual mark (SPEC §5.7)
            // can sit on a block Claude has not analyzed yet (a manual mark
            // on a non-analyzed block is allowed), and it must still show up
            // on the PDF. A block with no marks (analyzed or not) simply
            // contributes nothing to the loop below.
            guard let blockAnalysis = context.analysis.blocks[block.id] else { continue }
            for mark in blockAnalysis.marks where !mark.hidden {
                let cleanRange = NSRange(location: mark.range.start, length: mark.range.length)
                let rects = lineRects(cleanRange: cleanRange, block: block, document: document, page: pageIndex)
                guard !rects.isEmpty else { continue }
                items.append(PageMarkItem(blockId: block.id, markId: mark.id, termId: mark.termId, type: mark.type, isRepetition: false, hidden: mark.hidden, pageIndex: pageIndex, lineRects: rects))
            }
        }

        // Computed once per CONTEXT instead of once per visible page; see the
        // comment on `AnalysisController.repetitionsCache`. `cachedRepetitions`
        // no longer computes anything here: it only reads the latest result
        // published by `AnalysisControllerRepetitions` (which runs off the
        // MainActor), never waiting for the next one, so this drawing is not
        // blocked.
        let repetitions = cachedRepetitions()
        for occurrence in repetitions {
            guard let block = context.blocks.first(where: { $0.id == occurrence.blockId }),
                  block.pageStart <= pageIndex, pageIndex <= block.pageEnd else { continue }
            let rects = lineRects(cleanRange: occurrence.range, block: block, document: document, page: pageIndex)
            guard !rects.isEmpty else { continue }
            let type = context.analysis.terms[occurrence.termId]?.type ?? .rectangle
            items.append(PageMarkItem(blockId: nil, markId: nil, termId: occurrence.termId, type: type, isRepetition: true, hidden: false, pageIndex: pageIndex, lineRects: rects))
        }

        markItemsCache[pageIndex] = items
        return items
    }

    private func cachedRepetitions() -> [Repetitions.Occurrence] {
        repetitionsCache ?? []
    }

    private func lineRects(cleanRange: NSRange, block: TextBlock, document: PDFDocument, page pageIndex: Int) -> [PageRect] {
        BlockSelectionResolver.selections(for: cleanRange, in: block, document: document).flatMap { selection in
            selection.selectionsByLine().compactMap { line -> PageRect? in
                guard let linePage = line.pages.first, document.index(for: linePage) == pageIndex else { return nil }
                return line.bounds(for: linePage)
            }
        }
    }
}
