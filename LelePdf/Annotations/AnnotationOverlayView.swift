import AppKit
@preconcurrency import PDFKit

/// Mouse interaction for the Annotate bar (SPEC §5.13), on top of
/// `MarksOverlayView` in the same `PDFView` (see `PDFKitView.swift`).
/// Captures events ONLY when needed: mouse events go to the overlay only
/// when a tool other than Select-on-empty-space is active. The text tools
/// build a point-to-point PDFKit selection (see `+TextMarkup.swift`), and
/// Select on empty space lets clicks through (normal PDF behavior).
@MainActor
final class AnnotationOverlayView: NSView {
    weak var model: DocumentModel?
    weak var pdfView: PDFView?
    var controller: AnnotationController? { model?.annotationController }

    private var renderer: AnnotationRenderer?
    private var selectionObserver: NSObjectProtocol?

    // State of a gesture in progress (shape/pen/polygon/eraser drag).
    private var dragStartPage: Int?
    private var dragStartPoint: CGPoint?
    private var liveShapeRect: CGRect?
    private var liveLinePoints: (CGPoint, CGPoint)?
    private var inkPoints: [CGPoint] = []
    private var polygonPoints: [CGPoint] = []
    private var polygonPage: Int?
    private var erasedIds: Set<String> = []
    private var isResizing: AnnotationHandle?

    /// The text tools cannot rely on the native `PDFView`: the real mouse
    /// target is one of its private `PDFPageView`s, which does not accept
    /// the first click while the window is not yet key. Also,
    /// `.PDFViewSelectionChanged` can arrive mid-drag, when the selection
    /// is still partial. So we keep the gesture's endpoints here and build a
    /// single `PDFSelection` on mouse-up.
    var textMarkupStartPage: PDFPage?
    var textMarkupStartPoint: CGPoint?
    var isHandlingTextMarkupDrag = false

    /// Active text box editor (SPEC "click on the page, type directly") and
    /// active note popover. Not `private`: managed by `+TextEditors.swift`
    /// (same type, separate file to keep files small).
    var activeTextBoxView: AnnotationTextBoxTextView?
    var activeNotePopover: AnnotationNotePopoverController?

    /// Annotation under the mouse (SPEC §5.13: the "delete" button is
    /// visible "when the note is selected OR under the mouse"): managed by
    /// `+DeleteButton.swift` (same type, separate file to keep files
    /// small), not persisted, UI only.
    var hoveredId: String?
    var deleteButtonTrackingArea: NSTrackingArea?

    init(model: DocumentModel, pdfView: PDFView) {
        self.model = model
        self.pdfView = pdfView
        super.init(frame: pdfView.bounds)
        autoresizingMask = [.width, .height]
        if let document = pdfView.document {
            let renderer = AnnotationRenderer(document: document)
            self.renderer = renderer
            renderer.refreshAll(model.annotationController.annotations)
        }
        model.annotationController.onAnnotationsChanged = { [weak self] in
            guard let self, let controller = self.controller else { return }
            self.renderer?.sync(controller.annotations)
            self.needsDisplay = true
            self.model?.readerBridge?.invalidateOverlay()
        }
        observeTextSelection()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.undoManager = window?.undoManager
    }

    /// Crash fix: without this explicit teardown, AppKit can still call
    /// `updateTrackingAreas()`/this view's layer drawing during the window's
    /// display cycle AFTER the view has been removed from the hierarchy,
    /// producing `EXC_BREAKPOINT`/`EXC_BAD_ACCESS` if it no longer has Swift
    /// referents and has already been deallocated. This was observed in tests
    /// that build real `NSWindow`/`PDFView` instances and tear them down by
    /// hand; production never hit it because it always closes the whole
    /// window instead of detaching this view on its own.
    /// Same principle as `MarksOverlayView.stopObserving()`, which had never
    /// been wired up for this view: `PDFKitView.dismantleNSView` now calls it
    /// here too, and `viewWillMove(toWindow:)` calls it on its own as soon as
    /// the view leaves its window (for example via `removeFromSuperview()`),
    /// not only when the `NSViewRepresentable`'s explicit teardown actually
    /// runs.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopObserving() }
    }

    func stopObserving() {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
        textMarkupStartPage = nil
        textMarkupStartPoint = nil
        isHandlingTextMarkupDrag = false
        removeDeleteButtonTrackingArea()
        activeNotePopover?.popover.performClose(nil)
        activeNotePopover = nil
        activeTextBoxView?.removeFromSuperview()
        activeTextBoxView = nil
    }

    override var isFlipped: Bool { false }

    /// Reloads all annotations (document open, SPEC "recreated ... on every
    /// open"): called by `PDFKitView` after the Store has published
    /// `annotationController.annotations` for the first time.
    func reloadAll() {
        guard let controller else { return }
        renderer?.refreshAll(controller.annotations)
        needsDisplay = true
    }

    // MARK: - hitTest (capture only when needed)

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let controller, controller.barVisible else { return nil }
        // The "delete" button of a selected note/text box, or one under the
        // mouse, captures the click BEFORE any per-tool logic. It must work
        // whatever tool is active, as in Preview.
        if deleteButtonHit(atViewPoint: point) != nil { return self }
        // Also capture dragging over text. Returning `nil` used to delegate
        // to a private PDFKit `PDFPageView`: on a window that was not yet key
        // the first click was lost and the selection notification could
        // arrive before the gesture ended.
        if controller.tool.isTextMarkup { return self }
        if controller.tool == .select {
            guard let (page, pagePoint) = pageAndPoint(for: point) else { return nil }
            if controller.selectedHandle(at: pagePoint) != nil { return self }
            return AnnotationHitTesting.topmostHit(controller.annotations, page: page, point: pagePoint) != nil ? self : nil
        }
        return self // drawing/eraser/text/note tool active: captures everything.
    }

    // MARK: - Page conversion

    /// Page and point in page space under a view point (same idea as
    /// `MarksOverlayView.markAt`, but here it is needed outside the marks
    /// too: every drawing tool).
    func pageAndPoint(for viewPoint: CGPoint) -> (page: Int, point: CGPoint)? {
        guard let pdfView, let document = pdfView.document,
              let page = pdfView.page(for: viewPoint, nearest: false) else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        return (index, pdfView.convert(viewPoint, to: page))
    }

    private func observeTextSelection() {
        guard let pdfView else { return }
        selectionObserver = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTextMarkupSelectionChanged() }
        }
    }

    // MARK: - Live feedback drawing (shape/pen/polygon in progress)

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let context = NSGraphicsContext.current?.cgContext else { return }
        PerfProbe.hit("overlay.annot.draw")
        // Independent of the live gesture below (often none is in
        // progress); see `+DeleteButton.swift`.
        drawDeleteButtons(pdfView: pdfView, context: context)
        guard let page = currentDrawingPage(pdfView: pdfView) else { return }
        context.saveGState()
        if let rect = liveShapeRect {
            context.addRect(pdfView.convert(rect, from: page))
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
        }
        if let (start, end) = liveLinePoints {
            context.move(to: pdfView.convert(start, from: page))
            context.addLine(to: pdfView.convert(end, from: page))
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
        }
        if inkPoints.count > 1 {
            context.move(to: pdfView.convert(inkPoints[0], from: page))
            for point in inkPoints.dropFirst() { context.addLine(to: pdfView.convert(point, from: page)) }
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(2)
            context.strokePath()
        }
        if polygonPoints.count > 1 {
            context.move(to: pdfView.convert(polygonPoints[0], from: page))
            for point in polygonPoints.dropFirst() { context.addLine(to: pdfView.convert(point, from: page)) }
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func currentDrawingPage(pdfView: PDFView) -> PDFPage? {
        guard let index = dragStartPage ?? polygonPage, let document = pdfView.document else { return nil }
        return document.page(at: index)
    }

    func setLiveShapeRect(_ rect: CGRect?) { liveShapeRect = rect; needsDisplay = true }
    func setLiveLinePoints(_ points: (CGPoint, CGPoint)?) { liveLinePoints = points; needsDisplay = true }
    func appendInkPoint(_ point: CGPoint) { inkPoints.append(point); needsDisplay = true }
    func resetInk() { inkPoints.removeAll(); needsDisplay = true }
    func appendPolygonPoint(_ point: CGPoint, page: Int) { polygonPoints.append(point); polygonPage = page; needsDisplay = true }
    func resetPolygon() { polygonPoints.removeAll(); polygonPage = nil; needsDisplay = true }

    var currentDragStartPage: Int? {
        get { dragStartPage }
        set { dragStartPage = newValue }
    }

    var currentDragStartPoint: CGPoint? {
        get { dragStartPoint }
        set { dragStartPoint = newValue }
    }

    var currentResizeHandle: AnnotationHandle? {
        get { isResizing }
        set { isResizing = newValue }
    }

    var currentPolygonPoints: [CGPoint] { polygonPoints }
    var currentPolygonPage: Int? { polygonPage }
    var currentInkPoints: [CGPoint] { inkPoints }
    var currentErasedIds: Set<String> {
        get { erasedIds }
        set { erasedIds = newValue }
    }
}
