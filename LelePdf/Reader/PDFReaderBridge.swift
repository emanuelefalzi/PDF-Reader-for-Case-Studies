import Foundation
@preconcurrency import PDFKit

/// Commands from the `DocumentModel` to the `PDFView`, in one direction
/// only: the model calls these methods and never observes the `PDFView`'s
/// state to decide whether to call them again. State flowing the other way
/// (current page, zoom, visible pages) arrives from `PDFReaderCoordinator`
/// through PDFKit notifications, so no loops form.
///
/// It also exposes access to the underlying `PDFView` for later milestones
/// (the marks overlay, scroll coordination with `Sync`).
@MainActor
final class PDFReaderBridge {
    private(set) weak var pdfView: PDFView?

    init(pdfView: PDFView) {
        self.pdfView = pdfView
    }

    // MARK: - Navigation

    func goToPage(_ index: Int) {
        guard let pdfView, let document = pdfView.document,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return }
        pdfView.go(to: page)
    }

    func go(to selection: PDFSelection) {
        guard let pdfView else { return }
        pdfView.setCurrentSelection(selection, animate: false)
        pdfView.go(to: selection)
    }

    /// The PDF's current text selection, read by ⌘⌥1…4
    /// (`DocumentModelManualToc.applyTocLevelShortcut`, a MENU command that
    /// otherwise has no access to the active window's `PDFView`).
    var currentSelection: PDFSelection? { pdfView?.currentSelection }

    /// Esc cancels an accumulated multi-selection ("the selection is
    /// cancelled with Esc"); it also removes PDFKit's native highlight, not
    /// just `DocumentModel.multiSelectionPieces`.
    func clearSelection() {
        pdfView?.setCurrentSelection(nil, animate: false)
    }

    /// Jump to a contents heading with a known position: a single call to
    /// `PDFDestination(page:at:)`, the same technique PDFKit uses to
    /// navigate from a PDF's built-in outline, never preceded or followed by
    /// another scroll call on the same side (a double scroll in sequence was
    /// the most likely cause of the choppy jump; see
    /// `DocumentModelTocNavigation.goToTocEntry`, which also wraps this call
    /// in `ScrollSyncCoordinator`'s reentrancy guard).
    func goToHeading(page index: Int, pageY: Double) {
        guard let pdfView, let document = pdfView.document,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return }
        let bounds = page.bounds(for: .mediaBox)
        let point = TocHeadingDestination.point(pageY: pageY, pageHeight: bounds.maxY, pageMinX: bounds.minX)
        pdfView.go(to: PDFDestination(page: page, at: point))
    }

    /// Page and position (page space) at the top of the part currently
    /// visible: the same technique as `MarksOverlayHover`
    /// (`page(for:nearest:)` plus point-to-page conversion), used to decide
    /// which contents heading to highlight in the Chapters sidebar based on
    /// the actual reading position, not just the page.
    func topVisiblePagePosition() -> (page: Int, pageY: Double)? {
        guard let pdfView, let document = pdfView.document else { return nil }
        let topEdge = CGPoint(x: pdfView.bounds.midX, y: pdfView.isFlipped ? pdfView.bounds.minY : pdfView.bounds.maxY)
        guard let page = pdfView.page(for: topEdge, nearest: true) else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        let pointOnPage = pdfView.convert(topEdge, to: page)
        return (pageIndex, Double(pointOnPage.y))
    }

    // MARK: - Zoom

    private static let zoomStep: CGFloat = 0.1

    func zoomIn() {
        guard let pdfView else { return }
        pdfView.scaleFactor = min(pdfView.scaleFactor + Self.zoomStep, pdfView.maxScaleFactor)
    }

    func zoomOut() {
        guard let pdfView else { return }
        pdfView.scaleFactor = max(pdfView.scaleFactor - Self.zoomStep, pdfView.minScaleFactor)
    }

    func zoomToActualSize() {
        pdfView?.scaleFactor = 1.0
    }

    // MARK: - Search (SPEC §5.10)

    func setHighlightedSelections(_ selections: [PDFSelection]?) {
        pdfView?.highlightedSelections = selections
    }

    // MARK: - Debug overlay (SPEC §11 row M2)

    private var debugAnnotator: DebugBlockAnnotator?

    /// Draws (or removes) the debug annotations for the blocks (see
    /// `DebugOverlay.swift` for the technical choice: temporary
    /// `PDFAnnotation`s rather than `pageOverlayViewProvider`, which proved
    /// unreliable at runtime). Called when `debugShowBlocks` changes or when
    /// the pipeline publishes `structure`.
    func updateDebugAnnotations(structure: DocumentStructure?, show: Bool) {
        guard let pdfView, let document = pdfView.document else { return }
        if debugAnnotator == nil { debugAnnotator = DebugBlockAnnotator(document: document) }
        debugAnnotator?.update(structure: structure, show: show)
    }

    /// The underlying scroll view, used to coordinate linked scrolling (M6).
    var enclosingScrollView: NSScrollView? {
        pdfView?.documentView?.enclosingScrollView
    }

    // MARK: - Marks overlay (SPEC §5.4, M5b)

    weak var marksOverlay: MarksOverlayView?

    /// Called when structure/analysis/hover change in a way the overlay does
    /// not pick up on its own (a new page, a newly saved analysis): redraws
    /// the visible marks.
    func invalidateOverlay() {
        marksOverlay?.invalidate()
    }

    // MARK: - Annotations overlay (SPEC §5.13, M7b)

    weak var annotationOverlay: AnnotationOverlayView?
}
