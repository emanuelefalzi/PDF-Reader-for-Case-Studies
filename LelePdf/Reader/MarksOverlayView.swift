import AppKit
@preconcurrency import PDFKit

/// Hover-change notification (SPEC §5.8): `DocumentModel.setHover` posts it;
/// `MarksOverlayView` (PDF) and `MarkedTextView` (right panel, M5b) observe
/// it to redraw, since neither is pure SwiftUI and so they do not update
/// themselves by following `@Observable`.
extension Notification.Name {
    static let lelePdfHoverChanged = Notification.Name("LelePdfHoverChanged")
    /// `DocumentModel.colorTheme` changed (SPEC §5.4 v2.6): posted by
    /// `DocumentModel.setColorTheme`. The PDF overlay already redraws on its
    /// own (`readerBridge?.invalidateOverlay()`, called by the same method)
    /// and does not observe this notification; it is needed by
    /// `MarkedNSTextView` (right panel), which `RewritePanel`/`BlockCardView`
    /// may skip entirely (`BlockCardView: Equatable`) when neither `blockId`
    /// nor `cardData` changes: the color alone would otherwise never
    /// invalidate them.
    static let lelePdfColorThemeChanged = Notification.Name("LelePdfColorThemeChanged")
}

/// Overlay of the 4 marks above the PDF (SPEC §5.4, §9, M5b deliverable 1).
///
/// [TECHNICAL CHOICE]: not `PDFView.pageOverlayViewProvider`. M2 had already
/// investigated that route thoroughly in the exact same configuration
/// (`PDFView` in an `NSViewRepresentable`, `displayMode =
/// .singlePageContinuous`): PDFKit never calls `overlayViewFor`, as
/// verified with diagnostic logs, regardless of assignment order. This view
/// is instead a single `NSView` added as a direct subview of `PDFView`
/// itself (not of `documentView`, which is private), as large as
/// `pdfView.bounds` with a flexible `autoresizingMask`: it draws only the
/// visible pages (`model.visiblePageRange`, SPEC §9), converting page-to-view
/// rectangles with `PDFView.convert(_:from:)` on every redraw, so it follows
/// zoom and scrolling without having to manage one view per page.
@MainActor
final class MarksOverlayView: NSView {
    weak var model: DocumentModel?
    weak var pdfView: PDFView?

    private var trackingArea: NSTrackingArea?
    /// Fill of the "concept" mark, drawn elsewhere with a true multiply
    /// against the PDF: set by `PDFKitView.makeNSView`, invalidated together
    /// with this view on every trigger (`invalidate()`, hover, scrolling,
    /// fade).
    weak var rectangleOverlay: RectangleMarksOverlay?
    /// Band of the paragraph "in focus": set by `PDFKitView.makeNSView`,
    /// invalidated together with this view on the same events as
    /// `rectangleOverlay` (focus change, scrolling, updated data), never on
    /// every single mouse event.
    weak var paragraphFocusOverlay: ParagraphFocusOverlay?

    /// Selection mini bar (SPEC §5.7, v2.3 §5.3, M7): logic in
    /// `MarksOverlaySelectionBar.swift` (same type, separate file to keep
    /// files small).
    let selectionBar = SelectionMiniBar()
    var selectionObserver: NSObjectProtocol?
    /// Local monitors for ⌘ multi-selection, logic in
    /// `MarksOverlayMultiSelection.swift` (same type, separate file to keep
    /// files small). `isAccumulatingMultiSelectionGesture` is true between the
    /// `mouseDown` that started a ⌘-drag and the `mouseUp` that ends it.
    var multiSelectionMouseDownMonitor: Any?
    var multiSelectionMouseUpMonitor: Any?
    var isAccumulatingMultiSelectionGesture = false
    /// The mini bar is not rebuilt on every `.PDFViewSelectionChanged` of a
    /// drag (dozens per second: `selectionsByLine`, block resolution, twelve
    /// new `NSButton`s each time) but ONCE at mouse-up. While the button is
    /// pressed the bar stays hidden and a pending refresh is flagged,
    /// consumed by the local mouse-up monitor
    /// (`MarksOverlayMultiSelection.swift`) on the next run loop pass, once
    /// PDFKit has finished its selection. `isLeftMouseButtonPressed` reads
    /// the real mouse state; the tests and the benchmark replace it to
    /// simulate a drag (there is no real mouse in `xctest`).
    var selectionBarRefreshPending = false
    var isLeftMouseButtonPressed: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Anchor of the bar in PAGE space (the rectangle of the selection or of
    /// the clicked mark). The bar used to be positioned just once in view
    /// space and stayed put while the text scrolled or zoomed beneath it: the
    /// scroll observer now repositions it from here
    /// (`repositionSelectionBar`), one conversion per event and only while it
    /// is visible.
    var selectionBarAnchor: (page: PDFPage, pageRect: CGRect)?
    /// SPEC §5.4 "Selected": a mark clicked with the "Change"/"Remove" bar
    /// still open (SPEC §5.7). Not `private`: read by
    /// `MarksOverlayDrawing.swift`, written by `MarksOverlaySelectionBar.swift`
    /// (same type, separate files to keep files small).
    var selectedMarkId: String?
    var selectedMarkBlockId: String?

    /// Appearance time of each new mark (by id), for the fade (SPEC §5.5
    /// "marks appear on the PDF with a fade"). Repetitions (without a
    /// `markId`) have no fade of their own.
    private var appearedAt: [String: Date] = [:]
    private var fadeTimer: Timer?
    private static let fadeDuration: TimeInterval = 0.32

    private var boundsObserver: NSObjectProtocol?
    private var hoverNotificationObserver: NSObjectProtocol?

    /// Rectangles already converted to view space, per visible page (SPEC
    /// §5.8 smoothness): computed just once per page on every real redraw
    /// (`draw(_:)`/`hitItems(forPage:)` rebuilds them if missing), no longer
    /// on every single mouse event. Emptied by `invalidate()` and on every
    /// scroll/zoom (the rectangles in page space stay valid, but their
    /// conversion to view space does not). Not `private`: also read/written
    /// by `MarksOverlayHover.swift`/`MarksOverlayDrawing.swift` (same type,
    /// separate files to keep files small).
    var hitCache: [Int: [(rects: [CGRect], item: PageMarkItem)]] = [:]
    /// Rectangles (view space) of each block's bounding box per page: a
    /// single rectangle per block, not one per mark line like `hitCache`. It
    /// is only used to know "which block is the mouse over" so the matching
    /// card can be accented (`DocumentModel.hoveredBlockId`, and also the
    /// margin marker), with the same caching idea as `hitCache` to avoid
    /// redoing `PDFView.convert` on every mouse event.
    var blockHitCache: [Int: [(rect: CGRect, blockId: String)]] = [:]
    /// Last full identity (term+mark+block) for which only the affected
    /// rectangle was redrawn instead of the whole view: it lets
    /// `setNeedsDisplay(in:)` invalidate both the mark that LOSES the
    /// highlight and the one that GAINS it. Not just `termId`, a reservation
    /// raised by an earlier cross-review: moving directly between two marks
    /// with the SAME termId but different `markId`/`blockId` (a term really
    /// marked in two independent blocks) did not change `termId`, so the
    /// redraw was skipped and the visual state stayed stale until an
    /// invalidation arrived for another reason.
    var lastHoverIdentity = HoverIdentity(termId: nil, markId: nil, blockId: nil)
    /// Last block "in focus" for which the margin bar was redrawn: it changes
    /// far less often than the hovered mark (per block, not per single
    /// mark), so a full redraw stays cheap.
    var lastFocusedBlockIdForRedraw: String?
    /// The mark currently under the mouse, already with rectangles in view
    /// space (`MarksOverlayHover.handleMouseMoved`): a shortcut to avoid
    /// redoing the hit test of ALL the marks on the page when the mouse has
    /// merely jittered inside the same mark as before between two consecutive
    /// `mouseMoved` events. Not `private`: read/written by
    /// `MarksOverlayHover.swift` (same type, separate file to keep files
    /// small).
    var currentHoverEntry: (pageIndex: Int, rects: [CGRect])?

    init(model: DocumentModel, pdfView: PDFView) {
        self.model = model
        self.pdfView = pdfView
        super.init(frame: pdfView.bounds)
        autoresizingMask = [.width, .height]
        addSubview(selectionBar)
        selectionBar.isHidden = true
        observeScrolling()
        hoverNotificationObserver = NotificationCenter.default.addObserver(forName: .lelePdfHoverChanged, object: model, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hoverChangedAt = CFAbsoluteTimeGetCurrent()
                self?.redrawForHoverChange()
            }
        }
        selectionObserver = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSelectionChanged() }
        }
        installMultiSelectionMonitor()
    }

    /// Redraws only the union of the rectangles of the marks whose computed
    /// state (`HoverLinking.state`) really changes between the old and the
    /// new hover identity, instead of the whole view (`needsDisplay = true`
    /// forced a redraw of ALL the visible marks on every mouse pass, not just
    /// the ones involved). Recomputing the real state (the same function the
    /// drawing uses) instead of a hand-written comparison by `termId`/id
    /// avoids the reservation from the earlier cross-review ("a change of
    /// markId with the same termId does not force the redraw"): a term really
    /// marked in two different blocks changes `markId`/`blockId` but not
    /// `termId`, and here the comparison is correct by construction, never
    /// based on a single field of the identity.
    private func redrawForHoverChange() {
        PerfProbe.measure("overlay.hoverChanged") { redrawForHoverChangeBody() }
    }

    private func redrawForHoverChangeBody() {
        let oldIdentity = lastHoverIdentity
        let newIdentity = HoverIdentity(termId: model?.hoveredTermId, markId: model?.hoveredMarkId, blockId: model?.hoveredMarkBlockId)
        lastHoverIdentity = newIdentity

        let oldFocusedBlockId = lastFocusedBlockIdForRedraw
        let newFocusedBlockId = model?.hoveredBlockId
        lastFocusedBlockIdForRedraw = newFocusedBlockId

        guard oldIdentity != newIdentity else {
            if oldFocusedBlockId != newFocusedBlockId {
                // The margin bar/band depends on the block in focus, not on
                // a specific mark: a full redraw stays simple and cheap (one
                // fill per visible block), and the change happens per block,
                // far less often than every pixel of hover over a mark.
                needsDisplay = true
                paragraphFocusOverlay?.needsDisplay = true
            }
            return
        }
        // `nil` if the cache does not yet cover all the visible pages (e.g.
        // right after a scroll, before the next `draw(_:)`): in that case a
        // full redraw is the only safe choice, but it stays rare (the cache
        // is repopulated on every real `draw(_:)`, which always precedes the
        // first possible hover on a page that has just appeared).
        guard let combined = unionRectOfChangedEntries(old: oldIdentity, new: newIdentity) else {
            needsDisplay = true
            rectangleOverlay?.needsDisplay = true
            paragraphFocusOverlay?.needsDisplay = true
            return
        }
        if oldFocusedBlockId != newFocusedBlockId {
            needsDisplay = true
            paragraphFocusOverlay?.needsDisplay = true
        }
        setNeedsDisplay(combined)
        rectangleOverlay?.setNeedsDisplay(combined)
    }

    /// Union (widened by a few points for the thicker stroke in hover state)
    /// of the view-space rectangles of every mark whose computed state
    /// differs between `old` and `new`: the SAME pure function used by the
    /// real drawing (`MarksOverlayDrawing.drawMarks`), never a hand-duplicated
    /// "which marks are involved" logic (the source of the reservation above).
    /// `nil` if at least one visible page is not yet in `hitCache`.
    private func unionRectOfChangedEntries(old: HoverIdentity, new: HoverIdentity) -> CGRect? {
        guard let model else { return nil }
        guard model.visiblePageRange.allSatisfy({ hitCache[$0] != nil }) else { return nil }
        var result: CGRect?
        for entries in hitCache.values {
            for entry in entries {
                let item = entry.item
                let oldState = HoverLinking.state(
                    markId: item.markId, blockId: item.blockId, termId: item.termId, isRepetition: item.isRepetition,
                    hoveredMarkId: old.markId, hoveredBlockId: old.blockId, hoveredTermId: old.termId
                )
                let newState = HoverLinking.state(
                    markId: item.markId, blockId: item.blockId, termId: item.termId, isRepetition: item.isRepetition,
                    hoveredMarkId: new.markId, hoveredBlockId: new.blockId, hoveredTermId: new.termId
                )
                guard oldState != newState else { continue }
                for rect in entry.rects {
                    let expanded = rect.insetBy(dx: -3, dy: -3)
                    result = result?.union(expanded) ?? expanded
                }
            }
        }
        return result ?? .zero
    }

    /// SPEC §5.8 "How to measure ... the time between hover and highlight"
    /// (M6): the instant of the last hover change not yet reflected by a
    /// `draw(_:)`, consumed there. Only the PDF side is measured (not
    /// `MarkedNSTextView` too), a choice made for the measurement setup.
    private var hoverChangedAt: CFAbsoluteTime?

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Explicit removal of the block-based observers. `NotificationCenter`
    /// keeps the token alive even with `[weak self]`; without this teardown
    /// every reopening of a PDF left three useless registrations in the
    /// notification center until the process ended.
    func stopObserving() {
        let center = NotificationCenter.default
        if let boundsObserver { center.removeObserver(boundsObserver) }
        if let hoverNotificationObserver { center.removeObserver(hoverNotificationObserver) }
        if let selectionObserver { center.removeObserver(selectionObserver) }
        boundsObserver = nil
        hoverNotificationObserver = nil
        selectionObserver = nil
        removeMultiSelectionMonitor()
        fadeTimer?.invalidate()
        fadeTimer = nil
        // Parity with `AnnotationOverlayView.stopObserving` (a crash in
        // `updateTrackingAreas()` of an already torn-down view): the tracking
        // area has an unretained `owner: self`.
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        selectionBarRefreshPending = false
    }

    private func observeScrolling() {
        guard let scrollView = pdfView?.documentView?.enclosingScrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The rectangles in PAGE space stay valid after a
                // scroll/zoom, but their conversion to VIEW space
                // (`hitCache`) does not: `draw(_:)` rebuilds it for the
                // visible pages before the user can move the mouse again.
                PerfProbe.hit("overlay.scroll.invalidate")
                self?.hitCache.removeAll()
                self?.blockHitCache.removeAll()
                // The hover shortcut is also in view space
                // (`currentHoverEntry`): left in place, the next `mouseMoved`
                // would compare it against rectangles that have already
                // slid away and could skip the update.
                self?.currentHoverEntry = nil
                self?.needsDisplay = true
                self?.rectangleOverlay?.needsDisplay = true
                self?.paragraphFocusOverlay?.needsDisplay = true
                self?.repositionSelectionBar()
            }
        }
    }

    /// Called when structure/analysis change (new marks, analyzed block):
    /// redraws and lets the next `draw` make the new marks appear with a
    /// fade. It also invalidates `rectangleOverlay`: the solid fill lives in a
    /// separate view, but follows the same fade. It also empties `hitCache`:
    /// the marks/rectangles themselves may have changed (a manual mark
    /// added, removed or retyped).
    func invalidate() {
        hitCache.removeAll()
        blockHitCache.removeAll()
        currentHoverEntry = nil // the marks themselves may have changed.
        needsDisplay = true
        rectangleOverlay?.needsDisplay = true
        paragraphFocusOverlay?.needsDisplay = true
    }

    /// The marks of `pageIndex` with rectangles ALREADY converted to view
    /// space: used both by the drawing (`MarksOverlayDrawing.drawMarks`) and
    /// by the hover hit test (`MarksOverlayHover`), so the
    /// `PDFView.convert(_:from:)` conversion happens just once per page per
    /// real redraw, not once per MARK on every single mouse event (SPEC §5.8
    /// "<16 ms").
    func hitItems(forPage pageIndex: Int) -> [(rects: [CGRect], item: PageMarkItem)] {
        if let cached = hitCache[pageIndex] { return cached }
        guard let model, let pdfView, let document = pdfView.document, let page = document.page(at: pageIndex) else { return [] }
        return PerfProbe.measure("overlay.hitItems.build") {
            let items = model.analysisController.markItems(forPage: pageIndex, document: document)
            let converted = items.map { item in (rects: item.lineRects.map { pdfView.convert($0, from: page) }, item: item) }
            hitCache[pageIndex] = converted
            return converted
        }
    }

    /// Rectangle (view space) of each block's bounding box on `pageIndex`, to
    /// know "which block is the mouse over" without redoing `PDFView.convert`
    /// on every event (same idea as `hitItems`).
    func blockHitItems(forPage pageIndex: Int) -> [(rect: CGRect, blockId: String)] {
        if let cached = blockHitCache[pageIndex] { return cached }
        guard let pdfView, let document = pdfView.document, let page = document.page(at: pageIndex),
              let blocks = model?.structure?.blocks else { return [] }
        let items: [(rect: CGRect, blockId: String)] = blocks.compactMap { block in
            guard block.pageStart <= pageIndex, pageIndex <= block.pageEnd,
                  let rects = block.lineRectsByPage[pageIndex], let union = MarkGeometry.boundingRect(of: rects) else { return nil }
            return (pdfView.convert(union, from: page), block.id)
        }
        blockHitCache[pageIndex] = items
        return items
    }

    override var isFlipped: Bool { false }

    /// Same scheme as `AnnotationOverlayView.acceptsFirstMouse`/
    /// `MapInteractionNSView`: a clickable mark must also respond to the
    /// first click received by a window that is not yet "key", not just
    /// activate it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The same window `UndoManager` used by `AnnotationController`
    /// (`AnnotationOverlayView.viewDidMoveToWindow`), not a separate
    /// instance, so ⌘Z/⇧⌘Z interleave manual marks and annotations in the
    /// real order in which the actions happened (a single system
    /// `UndoManager` per window).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        model?.analysisController.undoManager = window?.undoManager
        // First view of the `PDFView` to already have a real `NSWindow`; see
        // `WindowResizeCoalescer`.
        if let window { model?.windowResizeCoalescer.attach(to: window) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // M7: the selection mini bar must be checked first: its buttons are
        // real subviews (`NSButton`), they need AppKit's real `hitTest`
        // routing, not just a `frame.contains`.
        if !selectionBar.isHidden, let hit = selectionBar.hitTest(point) { return hit }
        // Bug found while using the app: with the Annotate bar on
        // Highlight/Underline/Strikethrough, `AnnotationOverlayView.hitTest`
        // deliberately already returns `nil` (SPEC §5.13 M7b-2 "ALWAYS nil,
        // leaving the PDFView's NATIVE selection to work"), but THIS view,
        // beneath it in the same `PDFView` (`PDFKitView.swift`), did not know
        // that and captured the click anyway whenever it landed on a mark
        // already drawn by the analysis (SPEC §5.4). The marks cover exactly
        // the "interesting" text (concepts/actors/actions/consequences):
        // without this check, dragging to highlight almost never started the
        // native selection, because the text one wants to highlight is
        // exactly the text already marked. Reproduced in
        // `AnnotationLiveInteractionTests.highlightToolMustIgnoreExistingMarksUnderTheClick`.
        if let controller = model?.annotationController, controller.barVisible, controller.tool.isTextMarkup { return nil }
        // SPEC §5.8 "the click brings the other side to it" (M6): a mark is
        // clickable, the rest of the page stays transparent to clicks (PDF
        // selection/scrolling stay with the underlying PDFView).
        if markAt(point) != nil { return self }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let item = markAt(point) else { return }
        model.syncCoordinator.handlePDFMarkClicked(termId: item.termId, markId: item.markId, blockId: item.blockId)
        // SPEC §5.7 "Change or remove: click an existing mark and the same
        // bar appears with 'Change' and 'Remove'" (M7).
        showMarkActionsBar(for: item, at: point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        handleMouseMoved(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    // MARK: - Drawing (SPEC §5.4, §5.5, §9: visible pages only)

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let pdfView, let document = pdfView.document else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var stillFading = false
        // `PerfProbe`: the overlay redraw is one of the stages measured by the
        // benchmark harness.
        PerfProbe.measure("overlay.marks.draw") {
            for pageIndex in model.visiblePageRange {
                guard let page = document.page(at: pageIndex) else { continue }
                stillFading = drawMarks(page: page, pageIndex: pageIndex, model: model, pdfView: pdfView, context: context) || stillFading
                drawMarginBars(page: page, pageIndex: pageIndex, model: model, pdfView: pdfView, context: context)
            }
        }
        if stillFading { scheduleFadeRedraw() }
        if let hoverChangedAt {
            let latencyMs = (CFAbsoluteTimeGetCurrent() - hoverChangedAt) * 1000
            model.syncCoordinator.measurement?.recordHover(latencyMs: latencyMs)
            self.hoverChangedAt = nil
        }
    }

    private func scheduleFadeRedraw() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fadeTimer = nil
                self?.needsDisplay = true
                self?.rectangleOverlay?.needsDisplay = true
                self?.paragraphFocusOverlay?.needsDisplay = true
            }
        }
    }

    /// Fade factor for a mark that has just appeared (1 = steady state).
    func fadeOpacity(id: String) -> Double {
        let now = Date()
        if let start = appearedAt[id] {
            let elapsed = now.timeIntervalSince(start)
            if elapsed >= Self.fadeDuration { return 1 }
            return max(0, min(1, elapsed / Self.fadeDuration))
        }
        appearedAt[id] = now
        return 0
    }
}
