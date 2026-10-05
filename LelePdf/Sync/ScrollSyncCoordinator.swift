import AppKit

/// Coordinator of the linked scrolling (SPEC §5.8): one instance per
/// window (`DocumentModel.syncCoordinator`, like `analysisController`).
/// It observes the two `NSScrollView`s (PDF via `PDFKitView`, right panel
/// via `RewriteScrollHost`) and moves one after the other on every frame,
/// without animation, only with "Follow the PDF" on (`model.followPDF`):
/// SPEC "Both sides can drive". The click on a linked mark/term (SPEC "the
/// click brings the other side to it") does not go through here for the
/// target lookup logic: see `ScrollSyncCoordinator+Clicks.swift`.
@MainActor
final class ScrollSyncCoordinator: NSObject {
    /// SPEC §5.8 "Reading line: at 30% of the visible height".
    static let readingLineFraction: CGFloat = 0.30

    weak var model: DocumentModel?
    private weak var pdfScrollView: NSScrollView?
    private weak var panelScrollView: NSScrollView?
    private var pdfObserver: NSObjectProtocol?
    private var panelObserver: NSObjectProtocol?
    /// The panel's visible part changes size/position even without
    /// scrolling (the header above grows by one line when the chapter path
    /// wraps, after a jump): the common reading line moves and the following
    /// side has to be put back in place.
    private var panelFrameObserver: NSObjectProtocol?
    /// A single registration per window (guard below in `attachPDF`),
    /// removed by `detach()`.
    private var resizeTransitionEndObserver: NSObjectProtocol?
    /// True if `rebuildAlignment()` was called while
    /// `model.windowResizeCoalescer.isTransitioning` was true (Full Screen/
    /// live resize in progress): the real rebuild happens only once, at
    /// `.lelePdfResizeTransitionEnded`, instead of on every intermediate
    /// frame of the animation; see `WindowResizeCoalescer.swift`.
    private var pendingAlignmentRebuildDuringTransition = false

    /// Same principle as `pendingAlignmentRebuildDuringTransition`/
    /// `WindowResizeCoalescer` but for a burst of ⌃+wheel/pinch
    /// (`PDFReaderCoordinator+WheelZoom.swift`): a SEPARATE GATE, not
    /// `model.windowResizeCoalescer`: that coalescer turns
    /// `pdfView.autoScales` off/on around the transition
    /// (`PDFReaderCoordinator.handleResizeTransitionEnded`), and turning it
    /// back on at the end of a zoom burst (`autoScales = true`, if it was
    /// before any manual zoom) IMMEDIATELY triggers PDFKit's "fit to width"
    /// re-adaptation, cancelling the zoom just chosen (verified against a
    /// real `PDFView`). A zoom burst must not touch `autoScales` at all
    /// (`pdfView.scaleFactor = ...` already turns it off by itself,
    /// permanently, exactly like ⌘+/⌘- today), so it needs a signal
    /// independent of the window resize one.
    private var isZoomGestureActive = false
    private var pendingAlignmentRebuildDuringZoomGesture = false

    func beginZoomGesture() {
        isZoomGestureActive = true
    }

    func endZoomGesture() {
        isZoomGestureActive = false
        guard pendingAlignmentRebuildDuringZoomGesture else { return }
        pendingAlignmentRebuildDuringZoomGesture = false
        rebuildAlignment()
    }

    /// SPEC "a programmatic scroll does not re-trigger the synchronization
    /// (no bouncing)". **Not** two flags "consume at the next notification
    /// from THAT side" (the earlier version, which caused a real stack
    /// overflow): `NSClipView.setBoundsOrigin` posts
    /// `boundsDidChangeNotification` **more than once and re-entrantly**
    /// during the same call (confirmed by the crash traceback:
    /// `setBoundsOrigin` → posts directly, AND separately through
    /// `_selfBoundsChanged`/`translateOriginToPoint:` → posts again, both
    /// BEFORE `setBoundsOrigin` returns). A flag consumed by the first of
    /// the two notifications left the second free to start as if it were a
    /// real gesture, triggering `drive` on the opposite side, which in turn
    /// did the same on the starting side: infinite bouncing between the two
    /// `NSScrollView`s until the stack was exhausted. **Fixed** with a
    /// single true re-entrancy guard: while we are executing OUR
    /// `DocumentSpace.scroll` (here or in `scrollToShow`), any scroll
    /// notification, on one side or the other, once or several times, is
    /// ignored, not just the first. It is cleared only after the
    /// `DocumentSpace.scroll` call has returned, so by construction it
    /// covers all the re-entrant notifications AppKit posts inside it.
    private var isApplyingProgrammaticScroll = false

    /// Further protection, beyond the re-entrancy guard above: ignores a
    /// target practically identical to the current position (difference
    /// < 0.5 pt): a double request to scroll to an already reached
    /// position must not redo the whole `drive`→`scroll`→notification
    /// round anyway.
    private static let scrollNoOpToleranceTopDown: CGFloat = 0.5

    /// Not `private(set)`: tests inject a synthetic sequence directly
    /// (`@testable import`), instead of going through the real
    /// `AlignmentBuilder`/PDFKit; see `ScrollSyncCoordinatorTests.swift`.
    var segments: [AlignmentSegment] = []
    private var lastPanelRowFrames: [String: CGRect] = [:]
    /// The last side moved by the user (or by a direct PDF navigation).
    /// After a segment rebuild (new card measurements, zoom, resize) the
    /// other side is brought back to the target from THIS side
    /// (`scheduleRedrive`): previously the following side stayed where it
    /// was, with the old segments, until the user's next gesture (measured:
    /// the deviation after a jump did not change at all in the following
    /// frames).
    private(set) var lastUserSide: SyncSide?

    /// An automatic `drive` (from a rebuild or from a change of the panel's
    /// frame) NEVER starts synchronously. The first version did, and `drive`
    /// from the panel side scrolls the PDF and updates the reading position
    /// → `ContinueButtonRow` changes height → the panel's frame/rectangles
    /// change → new rebuild or frame notification → `drive` …: an endless
    /// loop, inside `layoutSubtreeIfNeeded` without ever returning to the
    /// run loop (31 and 38 GB of footprint in ~75 s, Mac frozen). Here: ONE
    /// `drive` per run loop turn (`redriveScheduled`), a re-entrancy guard
    /// of its own (`isDriving`) and a budget of automatic `drive`s per real
    /// gesture (`automaticRedriveBudget`, reset by `handleScrolled`/
    /// `followAfterNavigation`): once exhausted, re-driving stops until the
    /// user moves something again, so any oscillation ends by construction.
    static let maxAutomaticRedrivesPerGesture = 24
    private var redriveScheduled = false
    private var isDriving = false
    private(set) var automaticRedriveBudget = maxAutomaticRedrivesPerGesture
    /// Diagnostics (tests/bench): automatic `drive`s executed and times the
    /// budget was exhausted.
    private(set) var automaticRedriveCount = 0
    private(set) var automaticRedriveBudgetExhaustedCount = 0

    /// SPEC §5.8 "How it is measured": non-`nil` only with
    /// `LELEPDF_MEASURE=1` in a Debug build (`SyncMeasurement.makeIfEnabled`).
    var measurement: SyncMeasurement?

    func attachPDF(scrollView: NSScrollView, model: DocumentModel) {
        self.model = model
        guard pdfScrollView !== scrollView || pdfObserver == nil else { return }
        if let pdfObserver { NotificationCenter.default.removeObserver(pdfObserver) }
        pdfScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        pdfObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScrolled(side: .pdf) }
        }
        // Initial state, as `PDFReaderCoordinator.attach` does for
        // page/scale: do not wait for the first scroll to know what to
        // highlight in the Chapters sidebar.
        model.updateCurrentReadingPosition()

        // A single registration per window, filtered on THIS model's
        // coalescer (`object:`), not `nil`, otherwise the end of a
        // transition on ANOTHER document window would still redo
        // `rebuildAlignment()` here.
        if resizeTransitionEndObserver == nil {
            resizeTransitionEndObserver = NotificationCenter.default.addObserver(
                forName: .lelePdfResizeTransitionEnded, object: model.windowResizeCoalescer, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.pendingAlignmentRebuildDuringTransition else { return }
                    self.pendingAlignmentRebuildDuringTransition = false
                    self.rebuildAlignment()
                }
            }
        }
    }

    func attachPanel(scrollView: NSScrollView, model: DocumentModel) {
        self.model = model
        guard panelScrollView !== scrollView || panelObserver == nil else { return }
        if let panelObserver { NotificationCenter.default.removeObserver(panelObserver) }
        panelScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        panelObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScrolled(side: .panel) }
        }
        if let panelFrameObserver { NotificationCenter.default.removeObserver(panelFrameObserver) }
        scrollView.contentView.postsFrameChangedNotifications = true
        panelFrameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePanelViewportChanged() }
        }
    }

    /// The clip view's frame changes INSIDE layout (`NSScrollView.tile`
    /// under `layoutSubtreeIfNeeded`): here we only schedule, never a
    /// synchronous `drive` (it was link (b) of the loop). Not during a
    /// resize transition: there the segments wait for the end and the final
    /// rebuild re-drives on its own.
    private func handlePanelViewportChanged() {
        guard !isApplyingProgrammaticScroll else { return }
        if let model, model.windowResizeCoalescer.isTransitioning { return }
        scheduleRedrive()
    }

    func detach() {
        let center = NotificationCenter.default
        if let pdfObserver { center.removeObserver(pdfObserver) }
        if let panelObserver { center.removeObserver(panelObserver) }
        if let panelFrameObserver { center.removeObserver(panelFrameObserver) }
        if let resizeTransitionEndObserver { center.removeObserver(resizeTransitionEndObserver) }
        pdfObserver = nil
        panelObserver = nil
        panelFrameObserver = nil
        resizeTransitionEndObserver = nil
        pdfScrollView = nil
        panelScrollView = nil
    }

    // MARK: - Segments (SPEC §5.8 "Alignment model")

    /// Called by `RewriteScrollHost` on every change of the measured row
    /// rectangles (new analysis, edit, window resize): the only signal that
    /// really matters for the panel side, since it does not change while
    /// scrolling (see `RowFramesPreferenceKey`).
    func updatePanelRowFrames(_ frames: [String: CGRect]) {
        guard frames != lastPanelRowFrames else { return }
        lastPanelRowFrames = frames
        rebuildAlignment()
    }

    /// Also called from the PDF side when the zoom changes
    /// (`PDFReaderCoordinator.handleScaleChanged`): page→document
    /// coordinates depend on the scale.
    ///
    /// During a live resize/Full Screen (a bug reported as "full screen takes
    /// 3 seconds"), `PDFView.autoScales` posts `.PDFViewScaleChanged` (so
    /// this call) on every frame of the animation; `AlignmentBuilder.build`
    /// runs over EVERY row of the document, not just the visible ones, so
    /// redoing it dozens of times in a single animation is the real measured
    /// cost. A single real rebuild, at the end of the transition
    /// (`resizeTransitionEndObserver` above), is enough: `segments` stays
    /// what it was in the meantime, so the linked scrolling during the
    /// animation itself (rare: the user does not scroll while the window is
    /// animating) would use slightly stale coordinates instead of blocking
    /// the main thread.
    func rebuildAlignment() {
        guard let model else { return }
        guard !model.windowResizeCoalescer.isTransitioning else {
            pendingAlignmentRebuildDuringTransition = true
            return
        }
        // Same principle, separate gate; see `isZoomGestureActive`.
        guard !isZoomGestureActive else {
            pendingAlignmentRebuildDuringZoomGesture = true
            return
        }
        let rebuilt = AlignmentBuilder.build(model: model, panelRowFrames: lastPanelRowFrames)
        // Re-drive only if the segments really changed: an identical
        // rebuild (same measurements, same zoom) must neither move anything
        // nor consume budget.
        guard rebuilt != segments else { return }
        segments = rebuilt
        scheduleRedrive()
    }

    /// After a segment rebuild or a change of the panel's frame, the side
    /// that was following is brought back to the target from the side the
    /// user moved last (previously it stayed where it was, with the old
    /// segments, until the next gesture: measured, the deviation after a
    /// jump did not change in the following frames). ONE `drive` per run
    /// loop turn, deferred (`DispatchQueue.main.async`): never inside layout
    /// or inside a notification, never more than one per turn even if ten
    /// requests arrive, and never beyond the per-gesture budget. It moves
    /// only the side that was already following: it does not contend with a
    /// gesture in progress on the other. Not `private`: the regression tests
    /// (`ScrollSyncRedriveTests`) call it directly, without going through
    /// `AlignmentBuilder`.
    func scheduleRedrive() {
        guard let model, model.followPDF, lastUserSide != nil, !segments.isEmpty else { return }
        guard automaticRedriveBudget > 0 else {
            automaticRedriveBudgetExhaustedCount += 1
            return
        }
        guard !redriveScheduled else { return }
        redriveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redriveScheduled = false
            self.performScheduledRedrive()
        }
    }

    private func performScheduledRedrive() {
        guard let model, model.followPDF, let side = lastUserSide, !segments.isEmpty else { return }
        guard automaticRedriveBudget > 0 else {
            automaticRedriveBudgetExhaustedCount += 1
            return
        }
        automaticRedriveBudget -= 1
        automaticRedriveCount += 1
        PerfProbe.measure("sync.redrive") { drive(from: side) }
    }

    /// A real user gesture (or an explicit navigation): reopens the budget
    /// of automatic `drive`s.
    private func noteUserGesture(side: SyncSide) {
        lastUserSide = side
        automaticRedriveBudget = Self.maxAutomaticRedrivesPerGesture
    }

    /// After a direct PDF navigation performed under
    /// `performGuardedNavigation` (jump to a title from the contents,
    /// `DocumentModelTocNavigation`): the scroll notification was
    /// suppressed on purpose, so the panel has to be brought along behind
    /// the PDF with an explicit `drive`. Previously nobody did, and with
    /// "Follow the PDF" on, the panel stayed where it was (measured: median
    /// deviation of 5,600 pt after a jump from the contents). It is a user
    /// action, outside layout: `drive` immediately, not deferred.
    func followAfterNavigation(side: SyncSide) {
        noteUserGesture(side: side)
        guard let model, model.followPDF else { return }
        drive(from: side)
    }

    // MARK: - Drive (SPEC §5.8 "When the user scrolls one side (A)")

    private func handleScrolled(side: SyncSide) {
        // Covers both the first and every subsequent re-entrant
        // notification of OUR own ongoing `DocumentSpace.scroll`, on both
        // sides (see the comment on `isApplyingProgrammaticScroll`).
        if isApplyingProgrammaticScroll { return }
        PerfProbe.hit(side == .pdf ? "sync.scrolled.pdf" : "sync.scrolled.panel")
        // This is a REAL scroll notification (not suppressed by the guard
        // above, so not a programmatic jump like `goToTocEntry`/`drive`):
        // it releases the pin on the entry just clicked from the contents,
        // if there was one (bug reported as "the title above gets
        // highlighted").
        model?.clearPinnedTocEntry()
        noteUserGesture(side: side)
        // The reading position for the Chapters sidebar follows every real
        // scroll of the PDF, not just page changes, and not only when
        // "Follow the PDF" is on (the guard below is only for `drive`, not
        // for this).
        if side == .pdf { model?.updateCurrentReadingPosition() }
        guard let model, model.followPDF else { return }
        PerfProbe.measure("sync.drive") { drive(from: side) }
    }

    /// Runs `body` (a direct jump, a single call to `PDFView.go(to:)` or
    /// equivalent) under the same re-entrancy guard as `drive`/
    /// `scrollToShow` (fixing a "jerky, not smooth" bug): even a single
    /// navigation call can make AppKit post several re-entrant scroll
    /// notifications within the same call (same principle documented above
    /// for `setBoundsOrigin`), which would otherwise trigger `drive` several
    /// times with different targets before settling.
    func performGuardedNavigation(_ body: () -> Void) {
        isApplyingProgrammaticScroll = true
        body()
        isApplyingProgrammaticScroll = false
    }

    private func drive(from side: SyncSide) {
        // Never nested (a re-entrant notification that reached this point
        // must not be able to restart a second `drive`).
        guard !isDriving else { return }
        isDriving = true
        defer { isDriving = false }
        guard !segments.isEmpty,
              let pdfScrollView, let panelScrollView else { return }
        let sourceScrollView = side == .pdf ? pdfScrollView : panelScrollView
        let targetScrollView = side == .pdf ? panelScrollView : pdfScrollView
        guard let (sourceTop, _) = DocumentSpace.visibleTopDown(sourceScrollView),
              let offsets = DocumentSpace.readingLineOffsets(pdf: pdfScrollView, panel: panelScrollView, fraction: Self.readingLineFraction) else { return }

        let frameStart = measurement != nil ? CFAbsoluteTimeGetCurrent() : nil

        let readingY = sourceTop + (side == .pdf ? offsets.pdf : offsets.panel)
        guard let lookup = AlignmentModel.segmentAt(y: readingY, side: side, segments: segments) else { return }
        let targetSide: SyncSide = side == .pdf ? .panel : .pdf
        let readingLineOffset = targetSide == .pdf ? offsets.pdf : offsets.panel
        let maxScroll = DocumentSpace.maxScrollTopDown(targetScrollView)
        let target = AlignmentModel.target(for: lookup, segments: segments, targetSide: targetSide, readingLineOffset: readingLineOffset, maxScroll: maxScroll)
        if let measurement, segments.indices.contains(lookup.index) {
            let segment = segments[lookup.index]
            let segStart = targetSide == .pdf ? segment.pdfStart : segment.panelStart
            let segEnd = targetSide == .pdf ? segment.pdfEnd : segment.panelEnd
            let height = max(segEnd - segStart, AlignmentModel.minSegmentHeight)
            let raw = segStart + lookup.fraction * height - readingLineOffset
            measurement.recordClampDiagnostic(raw: raw, maxScroll: maxScroll, targetIsPDF: targetSide == .pdf)
        }

        guard let (currentTargetTop, _) = DocumentSpace.visibleTopDown(targetScrollView), abs(target - currentTargetTop) >= Self.scrollNoOpToleranceTopDown else { return }

        isApplyingProgrammaticScroll = true
        let appliedTop = DocumentSpace.scroll(targetScrollView, topDownTop: target)
        isApplyingProgrammaticScroll = false

        // The scroll notification of the PDF side resulting from this
        // programmatic scroll is suppressed by the guard above (as already
        // commented for `goToTocEntry`): when the panel drives the PDF,
        // update `currentPageIndex`/`currentReadingPageY` here, otherwise
        // they stay anchored to the page prior to the scroll (a known use
        // case bug, see `updateCurrentReadingPosition`).
        if targetSide == .pdf {
            model?.updateCurrentReadingPosition()
        }

        if let frameStart, let measurement {
            let durationMs = (CFAbsoluteTimeGetCurrent() - frameStart) * 1000
            let offset = AlignmentModel.offsetAfterApplying(
                lookup,
                segments: segments,
                targetSide: targetSide,
                appliedTop: appliedTop,
                readingLineOffset: readingLineOffset
            )
            measurement.recordFrame(offsetPt: offset, durationMs: durationMs)
        }
    }

    // MARK: - Direct navigation (click, SPEC "the click brings the other side to it")

    /// Scrolls `side` so that `topDownY` (document space of that side) ends
    /// up at the reading line. Unlike `drive(from:)` it does not go through
    /// `AlignmentModel`: the destination position is already known directly
    /// (a precise mark/term), not to be interpolated between segments. Not
    /// conditioned on "Follow the PDF" (SPEC: the click always brings the
    /// other side to the target; only the continuous following scroll is
    /// conditioned on the switch).
    func scrollToShow(side: SyncSide, topDownY: CGFloat) {
        guard let scrollView = side == .pdf ? pdfScrollView : panelScrollView,
              let (_, height) = DocumentSpace.visibleTopDown(scrollView) else { return }
        var readingLineOffset = height * Self.readingLineFraction
        if let pdfScrollView, let panelScrollView,
           let offsets = DocumentSpace.readingLineOffsets(pdf: pdfScrollView, panel: panelScrollView, fraction: Self.readingLineFraction) {
            readingLineOffset = side == .pdf ? offsets.pdf : offsets.panel
        }
        isApplyingProgrammaticScroll = true
        DocumentSpace.scroll(scrollView, topDownTop: topDownY - readingLineOffset)
        isApplyingProgrammaticScroll = false
        // The panel→PDF click scrolls `NSClipView`: it updates the page and
        // position without relying on PDFKit's unreliable notification.
        if side == .pdf { model?.updateCurrentReadingPosition() }
    }

    // MARK: - Measurement (debug/tests, SPEC "How it is measured")

    var pdfScrollViewForMeasurement: NSScrollView? { pdfScrollView }
    var panelScrollViewForMeasurement: NSScrollView? { panelScrollView }
}
