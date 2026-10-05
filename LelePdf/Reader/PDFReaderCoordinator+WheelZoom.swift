import AppKit
@preconcurrency import PDFKit

/// Ctrl+mouse wheel zooms in or out depending on the direction, as it does
/// in Word (requested by the user). An extension kept separate from
/// `PDFReaderCoordinator.swift` to keep files at or under ~12 KB, like
/// `MarksOverlayHover.swift` for `MarksOverlayView`.
///
/// [TECHNICAL CHOICE] A local monitor (`NSEvent.addLocalMonitorForEvents`),
/// not an `override scrollWheel(_:)`/`magnify(_:)` on a view of ours: the
/// marks overlay (`MarksOverlayView`) lets the wheel through to the
/// underlying `PDFView` for most of the page (its `hitTest` returns `nil`
/// outside a mark, SPEC §5.4), so an instance override on a view of OURS
/// would never intercept it for most points, and `PDFKitView.makeNSView`
/// uses a plain `PDFView`, not a subclass. The monitor is LOCAL, never
/// `addGlobalMonitorForEvents`: it only sees events already addressed to a
/// window of THIS app, so it cannot alter the system accessibility zoom
/// (⌃+wheel) of OTHER apps. Each document window has its own
/// `PDFReaderCoordinator`/monitor, filtered below on
/// `event.window === (its OWN pdfView.window)`, so two open windows do not
/// steal each other's events.
@MainActor
extension PDFReaderCoordinator {
    func installWheelZoomMonitor() {
        guard wheelZoomMonitor == nil else { return }
        wheelZoomMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            self?.handleZoomCandidate(event) ?? event
        }
    }

    func removeWheelZoomMonitor() {
        if let wheelZoomMonitor { NSEvent.removeMonitor(wheelZoomMonitor) }
        wheelZoomMonitor = nil
        wheelZoomEndTimer?.invalidate()
        wheelZoomEndTimer = nil
    }

    /// `nil` = event consumed (the zoom has already applied it, no
    /// scrolling/pinch behind it). The original event = let through intact
    /// (normal scrolling without ⌃, or ⌃+wheel outside our PDF/app not in
    /// the foreground).
    private func handleZoomCandidate(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            return handleScrollWheel(event)
        case .magnify:
            return handleMagnify(event)
        default:
            return event
        }
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.control) else { return event }
        guard let point = pointOverOurPDF(for: event) else { return event }

        // "Line" wheel (mechanical mouse, `hasPreciseScrollingDeltas ==
        // false`): `scrollingDeltaY` is in "notches" (typically ±1..±3), an
        // order of magnitude below trackpad points; without this factor the
        // zoom would be imperceptible with a real mouse.
        let rawDelta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * Self.lineDeltaScale
        let signedDelta = PDFZoomGesture.invertWheelDirection ? -rawDelta : rawDelta

        applyWheelZoomStep(rawDelta: signedDelta, atWindowPoint: point)
        noteZoomGestureEvent(phase: event.phase)
        return nil
    }

    private func handleMagnify(_ event: NSEvent) -> NSEvent? {
        guard let point = pointOverOurPDF(for: event) else { return event }
        applyMagnifyZoomStep(magnification: event.magnification, atWindowPoint: point)
        noteZoomGestureEvent(phase: event.phase)
        return nil
    }

    /// Only if the cursor is over OUR `PDFView` and the app is in the
    /// foreground. A local monitor only sees this app's windows anyway, but
    /// an event can still arrive for ANOTHER document window
    /// (`event.window`) or with the cursor over another view (sidebar, right
    /// panel).
    ///
    /// `model.hasTransientOverlay` (chat SPEC §5.9 or expanded map SPEC §5.3,
    /// `DocumentCommands.swift`): the expanded map draws above `ReaderPane()`
    /// in the SAME `ZStack` (`ThreePaneLayout.swift`), with the same area
    /// and window as the PDF underneath; without this exclusion our monitor
    /// would steal pinch/⌃+wheel from it (`MapInteractionLayer.magnify(with:)`/
    /// `scrollWheel(with:)`, which would otherwise never see them, since the
    /// local monitor runs before the normal forwarding to the view under the
    /// cursor).
    private func pointOverOurPDF(for event: NSEvent) -> CGPoint? {
        guard NSApp.isActive else { return nil }
        return zoomAnchorPointIgnoringActivation(window: event.window, locationInWindow: event.locationInWindow)
    }

    /// All of `pointOverOurPDF` except `NSApp.isActive` (which a test process
    /// cannot control). It uses `DocumentModel.readerGesturesBlockedByOverlay`
    /// (chat, expanded map) in place of `hasTransientOverlay`, which now also
    /// covers an open search and ⌘ multi-selection; neither covers the PDF,
    /// and zooming with the search open had become impossible. Not `private`:
    /// `ReaderReviewF17Tests` verifies it directly.
    func zoomAnchorPointIgnoringActivation(window eventWindow: NSWindow?, locationInWindow: CGPoint) -> CGPoint? {
        guard model?.readerGesturesBlockedByOverlay != true,
              let pdfView, let window = pdfView.window, eventWindow === window else { return nil }
        let pointInView = pdfView.convert(locationInWindow, from: nil)
        guard pdfView.bounds.contains(pointInView) else { return nil }
        return locationInWindow
    }

    // MARK: - Application (testable without a synthetic NSEvent, see `PDFWheelZoomApplicationTests.swift`)

    /// Not `private`: the tests call these two methods directly with
    /// hand-picked coordinates, sidestepping the construction (unreliable via
    /// the public API) of a real wheel/pinch `NSEvent`.
    func applyWheelZoomStep(rawDelta: CGFloat, atWindowPoint windowPoint: CGPoint) {
        applyAnchoredZoom(atWindowPoint: windowPoint) { current, minScale, maxScale in
            PDFZoomGesture.newScale(currentScale: current, rawDelta: rawDelta, minScale: minScale, maxScale: maxScale)
        }
    }

    func applyMagnifyZoomStep(magnification: CGFloat, atWindowPoint windowPoint: CGPoint) {
        applyAnchoredZoom(atWindowPoint: windowPoint) { current, minScale, maxScale in
            PDFZoomGesture.newScale(currentScale: current, magnification: magnification, minScale: minScale, maxScale: maxScale)
        }
    }

    /// Applies one zoom step anchored on the cursor: the pure math is in
    /// `PDFZoomGesture` (no `NSEvent`/PDFKit there), and this is just the
    /// bridge to the real `PDFView`/`NSClipView`. Scale limits are re-read
    /// from `pdfView.minScaleFactor`/`maxScaleFactor`, THE SAME as
    /// `PDFReaderBridge.zoomIn()`/`zoomOut()` (consistent with ⌘+/⌘-/⌘0),
    /// never assigned explicitly: doing so would turn `autoScales` off for
    /// good (`PDFView.h`, "Assigning these values will implicitly turn off
    /// autoScales") and break the automatic fit-to-width on
    /// open/resize (SPEC §5.1); here we only READ them.
    private func applyAnchoredZoom(atWindowPoint windowPoint: CGPoint, _ newScale: (_ current: CGFloat, _ minScale: CGFloat, _ maxScale: CGFloat) -> CGFloat) {
        guard let pdfView, let scrollView = model?.readerBridge?.enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let oldScale = pdfView.scaleFactor
        let targetScale = newScale(oldScale, pdfView.minScaleFactor, pdfView.maxScaleFactor)
        guard abs(targetScale - oldScale) > 0.0001 else { return }

        // Captured BEFORE changing the scale: afterwards, `clipView.bounds.
        // origin` would already be the (unknown) one PDFKit itself chose in
        // its internal automatic refit, no longer the starting one that
        // `PDFZoomGesture.anchoredOrigin` is based on.
        let oldOrigin = clipView.bounds.origin
        let contentPointBefore = clipView.convert(windowPoint, from: nil)
        // Offset of the cursor INSIDE the visible rectangle (0...viewport
        // width/height): the only quantity that does not change during this
        // zoom step, unlike the document origin (which shifts) or the position
        // in the document (which scales), because the cursor and the window
        // stay put.
        let mouseViewportOffset = CGPoint(x: contentPointBefore.x - oldOrigin.x, y: contentPointBefore.y - oldOrigin.y)

        // The point under the cursor in PAGE coordinates (PDF space,
        // independent of scale), captured BEFORE changing `scaleFactor`
        // because `pdfView.convert(_:to:)` uses the CURRENT scale to translate
        // from view space to page space: after the scale change this same
        // call would already give a different point. This fixes a reported
        // bug: zooming out with ctrl+wheel jumped to the last page, even
        // though the direction was right.
        let viewPoint = pdfView.convert(windowPoint, from: nil)
        let anchorPage = pdfView.page(for: viewPoint, nearest: true)
        let anchorPagePoint = anchorPage.map { pdfView.convert(viewPoint, to: $0) }

        // Setting `scaleFactor` turns `autoScales` off on its own (verified
        // against a real `PDFView`, not just documented for
        // `minScaleFactor`/`maxScaleFactor`): the zoom chosen here stays put
        // even at the next window resize, as ⌘+/⌘- already do today.
        pdfView.scaleFactor = targetScale

        // Real cause of that bug: the linear formula of
        // `PDFZoomGesture.anchoredOrigin` (a scale delta applied to a single
        // global origin) does NOT account for how PDFKit actually lays out the
        // pages in continuous mode (margins between pages, centering when
        // the content is smaller than the viewport), an approximation that
        // holds for most zoom levels but diverges exactly when the valid
        // scroll space collapses (zooming out below the fit scale),
        // "resolving" every time to the same limit page (the last), never a
        // random one. **Fixed** by computing the origin DIRECTLY from where
        // the anchored page point now falls in document space at the NEW
        // scale (`pdfView.convert(_:from:)`, which knows PDFKit's true
        // geometry, not an approximation of ours) minus the cursor's offset in
        // the viewport: if that point stays put on screen, the page that
        // contains it cannot change. The linear formula stays as a fallback
        // for the sole case (never observed with `nearest: true` on a
        // non-empty document) where no page to anchor to was found.
        let newOrigin: CGPoint
        if let anchorPage, let anchorPagePoint {
            let anchorDocumentPoint = pdfView.convert(anchorPagePoint, from: anchorPage)
            newOrigin = CGPoint(x: anchorDocumentPoint.x - mouseViewportOffset.x, y: anchorDocumentPoint.y - mouseViewportOffset.y)
        } else {
            newOrigin = PDFZoomGesture.anchoredOrigin(oldOrigin: oldOrigin, mouseViewPoint: mouseViewportOffset, oldScale: oldScale, newScale: targetScale)
        }
        let constrained = clipView.constrainBoundsRect(CGRect(origin: newOrigin, size: clipView.bounds.size))

        // Must not conflict with linked scrolling: like
        // `ScrollSyncCoordinator.performGuardedNavigation` for a direct jump,
        // the scroll that compensates the zoom must not re-trigger `drive()`
        // toward the panel with segments not yet updated (a burst is in
        // progress, the real rebuild is deferred below).
        let scrollAndRestorePage = {
            clipView.scroll(to: constrained.origin)
            scrollView.reflectScrolledClipView(clipView)
            // Final safety net, for the sole edge case where
            // `constrainBoundsRect` still moved the requested origin (document
            // edge reached): if the page under the cursor has still changed
            // relative to the anchored one, we explicitly go back to the
            // starting page. The guarantee that matters to the user ("the page
            // must not change during a pure zoom",
            // `PDFWheelZoomPageStabilityTests.swift`) must never silently
            // depend on the computation above alone. The point under the
            // cursor is re-derived HERE, not by reusing `viewPoint` (computed
            // BEFORE the scale change): the document view was resized by the
            // new `scaleFactor`, so its local coordinates are no longer the
            // same, whereas the window/cursor never moved, so `windowPoint`
            // remains the only valid reference to convert again.
            let currentViewPoint = pdfView.convert(windowPoint, from: nil)
            if let anchorPage, pdfView.page(for: currentViewPoint, nearest: true) !== anchorPage {
                // NOT `pdfView.go(to: anchorPage)`: that method aligns the
                // requested page to the top of the viewport, it does not
                // CENTER it. At a scale already below the fit (this branch;
                // the rendered page is shorter than the viewport) aligning to
                // the top leaves the lower part of the viewport uncovered,
                // where the anchored cursor (often toward the center, as in the
                // real case reported) falls on the NEXT page, which
                // `pdfView.currentPage` then judges "current" because it
                // occupies more visible area, reproducing the same symptom with
                // another page instead of fixing it (observed with a real
                // burst, `PDFWheelZoomPageStabilityTests.
                // burstZoomOutBelowFitToWindowKeepsThePageStable`). Centering
                // the anchored page in the viewport instead makes it
                // unambiguously the most represented one (and hence "current"
                // for PDFKit) regardless of exactly where the cursor is inside
                // it.
                let pageRectInDocument = pdfView.convert(anchorPage.bounds(for: pdfView.displayBox), from: anchorPage)
                let viewportSize = clipView.bounds.size
                let centeredOrigin = CGPoint(
                    x: pageRectInDocument.midX - viewportSize.width / 2,
                    y: pageRectInDocument.midY - viewportSize.height / 2
                )
                let centeredConstrained = clipView.constrainBoundsRect(CGRect(origin: centeredOrigin, size: viewportSize))
                clipView.scroll(to: centeredConstrained.origin)
                scrollView.reflectScrolledClipView(clipView)
            }
        }
        if let syncCoordinator = model?.syncCoordinator {
            syncCoordinator.performGuardedNavigation(scrollAndRestorePage)
        } else {
            scrollAndRestorePage()
        }
    }

    private static let lineDeltaScale: CGFloat = 10

    // MARK: - Coalescing (a zoom gesture extends the window-resize coalescing)

    /// A burst of ⌃+wheel/pinch signals its start to
    /// `ScrollSyncCoordinator` (a gate SEPARATE from `WindowResizeCoalescer`;
    /// see the comment on `ScrollSyncCoordinator.beginZoomGesture` for why its
    /// notifications/its effect on `autoScales` are not reused), then re-arms
    /// a safety timer: if no other notch arrives within
    /// `zoomGestureQuietPeriod`, or if the event already carries an
    /// `.ended`/`.cancelled` phase (trackpad/Magic Mouse, not a mechanical
    /// wheel), the burst ends and the real rebuild (`AlignmentBuilder.build`,
    /// deferred for the whole burst) happens just ONCE.
    private func noteZoomGestureEvent(phase: NSEvent.Phase) {
        model?.syncCoordinator.beginZoomGesture()
        wheelZoomEndTimer?.invalidate()
        if phase == .ended || phase == .cancelled {
            endZoomGestureNow()
            return
        }
        wheelZoomEndTimer = Timer.scheduledTimer(withTimeInterval: Self.zoomGestureQuietPeriod, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endZoomGestureNow() }
        }
    }

    private static let zoomGestureQuietPeriod: TimeInterval = 0.15

    private func endZoomGestureNow() {
        wheelZoomEndTimer?.invalidate()
        wheelZoomEndTimer = nil
        model?.syncCoordinator.endZoomGesture()
    }
}
