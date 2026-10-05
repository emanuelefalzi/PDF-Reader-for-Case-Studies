import AppKit
@preconcurrency import PDFKit

/// Hover over the marks (for linked highlighting, SPEC §5.8) and over the
/// block "in focus": an extension kept separate from
/// `MarksOverlayView.swift` to keep files at or under ~12 KB.
///
/// The floating pill that used to appear above a not-yet-analyzed paragraph
/// ("analyze from here") was removed at the user's request: the "analyze
/// this section" action now lives in the selection bar
/// (`MarksOverlaySelectionBar.swift`), together with the 4 marks and T1-T4,
/// no longer floating over the text.
@MainActor
extension MarksOverlayView {
    func handleMouseMoved(at point: CGPoint) {
        PerfProbe.measure("overlay.mouseMoved") { handleMouseMovedBody(at: point) }
    }

    private func handleMouseMovedBody(at point: CGPoint) {
        guard let model, let pdfView, let document = pdfView.document,
              let page = pdfView.page(for: point, nearest: false) else {
            clearHover()
            return
        }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { clearHover(); return }

        // "Which block is the mouse over" is independent of "which mark is
        // the mouse over" below, so it is always computed, with the same
        // per-page cache as `blockHitItems` (no repeated `PDFView.convert`
        // for every event). It also drives the band/marker of the paragraph
        // in focus on the PDF, and lets the matching card be accented.
        updateHoveredBlock(point: point, pageIndex: pageIndex, model: model)

        // SPEC §5.8 "<16 ms": if the mouse is still inside the SAME mark as
        // before (typical during a hover pause: AppKit keeps delivering
        // `mouseMoved` for every micro-movement), there is nothing to
        // recompute: no scan of the marks, no `setHover` (already equal;
        // `setHover` itself is a no-op but getting there still cost time).
        if let current = currentHoverEntry, current.pageIndex == pageIndex, MarkGeometry.hitTest(point, rects: current.rects) {
            return
        }

        // Marks: if the mouse is over a mark, highlight the term (SPEC §5.8
        // "Hover on a mark in the PDF"). `hitItems(forPage:)`: rectangles
        // already converted to view space, computed once per page per real
        // redraw, no longer one `PDFView.convert` per mark per mouse event.
        for entry in hitItems(forPage: pageIndex) {
            if MarkGeometry.hitTest(point, rects: entry.rects) {
                let item = entry.item
                currentHoverEntry = (pageIndex: pageIndex, rects: entry.rects)
                // The exact target always goes together with ITS block:
                // `markId` alone is not unique in the document (numbering is
                // local to the block); the user had reported far more marks
                // lighting up than expected. For a repetition
                // (`item.markId == nil`) SPEC §5.8 asks for "the term's mark
                // in its first block": `firstVisibleMark` carries that block
                // too, not just the markId.
                if let markId = item.markId {
                    model.setHover(termId: item.termId, markId: markId, blockId: item.blockId)
                } else if let target = model.analysisController.firstVisibleMark(for: item.termId) {
                    model.setHover(termId: item.termId, markId: target.markId, blockId: target.blockId)
                } else {
                    model.setHover(termId: item.termId, markId: nil, blockId: nil)
                }
                return
            }
        }
        currentHoverEntry = nil
        model.setHover(termId: nil, markId: nil, blockId: nil)
    }

    /// SPEC §5.6/§5.8: updates `DocumentModel.hoveredBlockId` from a mouse
    /// position in the PDF (to accent the matching card and to strengthen
    /// the band/marker of the paragraph in focus), independent of whether
    /// the pointer is over an actual mark.
    private func updateHoveredBlock(point: CGPoint, pageIndex: Int, model: DocumentModel) {
        model.setHoveredBlock(hoveredBlockAt(point: point, pageIndex: pageIndex, model: model))
    }

    /// The block whose rectangle (view space, `blockHitItems`) contains
    /// `point` on `pageIndex`, if any.
    private func hoveredBlockAt(point: CGPoint, pageIndex: Int, model: DocumentModel) -> String? {
        blockHitItems(forPage: pageIndex).first { $0.rect.contains(point) }?.blockId
    }

    func clearHover() {
        currentHoverEntry = nil
        model?.setHover(termId: nil, markId: nil, blockId: nil)
        model?.setHoveredBlock(nil)
    }

    /// The mark under `point` (this view's space), if any: used both by
    /// `hitTest`/the click (SPEC §5.8 "the click brings the other side to
    /// it", M6) and, in the future, by other point reads. It duplicates a
    /// small part of the first pass of `handleMouseMoved` instead of sharing
    /// it, so as not to touch that already verified M5b logic. It uses the
    /// same `hitItems(forPage:)` (rectangles already converted, no repeated
    /// `PDFView.convert`).
    func markAt(_ point: CGPoint) -> PageMarkItem? {
        guard let pdfView, let document = pdfView.document,
              let page = pdfView.page(for: point, nearest: false) else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        for entry in hitItems(forPage: pageIndex) {
            if MarkGeometry.hitTest(point, rects: entry.rects) { return entry.item }
        }
        return nil
    }
}
