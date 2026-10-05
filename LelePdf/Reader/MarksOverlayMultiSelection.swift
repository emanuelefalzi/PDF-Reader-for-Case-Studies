import AppKit
@preconcurrency import PDFKit

/// Multi-selection with ⌘ (hold ⌘ and select every piece you consider a
/// level-2 heading, then turn them all into T2 in one go). `PDFView`
/// natively handles a single `PDFSelection` at a time (replaced on every
/// drag): this extension observes mouse events with a LOCAL `NSEvent`
/// monitor (`addLocalMonitorForEvents`, never a `hitTest`/`mouseDown`
/// override, since we must NEVER steal the click from the underlying
/// `PDFView`, the same lesson learned from clicks stolen by the marks and
/// annotation overlays) to know WHETHER ⌘ was down at the start of the
/// gesture, and composes the pieces with `PDFSelection.add(_:)` at the end of
/// the drag (`mouseUp`).
///
/// The accumulated state lives on `DocumentModel.multiSelectionPieces` (not
/// on this view): it is also read/consumed by ⌘⌥1…4
/// (`DocumentModel.applyTocLevelShortcut`, a MENU command that otherwise has
/// no visibility into the mouse gesture) and by Esc
/// (`DocumentModel.closeTransientOverlays`).
@MainActor
extension MarksOverlayView {
    /// Installed by `init` (`MarksOverlayView.swift`), removed by
    /// `stopObserving()`. It ALWAYS returns the event unchanged: a local
    /// monitor observes, it does not intercept. `PDFView` still receives the
    /// event and makes its native selection; this code only reads whether ⌘
    /// was down and, at the end of the gesture, recomposes the pieces.
    func installMultiSelectionMonitor() {
        multiSelectionMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMultiSelectionMouseDown(event)
            return event
        }
        multiSelectionMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.handleMultiSelectionMouseUp(event)
            // The mini bar deferred to mouse-up
            // (`MarksOverlaySelectionBar.swift`) runs AFTER the pieces above
            // are recomposed, so the bar sees the final selection.
            self?.handleSelectionBarMouseUp()
            return event
        }
    }

    func removeMultiSelectionMonitor() {
        if let multiSelectionMouseDownMonitor { NSEvent.removeMonitor(multiSelectionMouseDownMonitor) }
        if let multiSelectionMouseUpMonitor { NSEvent.removeMonitor(multiSelectionMouseUpMonitor) }
        multiSelectionMouseDownMonitor = nil
        multiSelectionMouseUpMonitor = nil
    }

    /// Not `private`: `MultiSelectionRealEventTests` calls it directly with a
    /// real `NSEvent` (`NSEvent.mouseEvent`), the same technique already used
    /// in this suite for another local monitor
    /// (`PDFReaderCoordinator.applyWheelZoomStep`,
    /// `PDFWheelZoomPageStabilityTests`). A local monitor hooks into the
    /// `NSApplication.sendEvent` pass, not a direct `NSWindow.sendEvent` (the
    /// technique this suite chose to stay stable).
    func handleMultiSelectionMouseDown(_ event: NSEvent) {
        guard let model, let pdfView, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        // With the Annotate bar open on a tool other than Select, the click
        // goes to `AnnotationOverlayView` (its `hitTest` captures
        // everything), not to the `PDFView`'s native selection: a ⌘-drag with
        // Highlight/pen/shapes is not a multi-selection gesture. Without this
        // guard the mouse-up accumulated the markup's provisional selection
        // and left `multiSelectionPieces` non-empty (Esc changed meaning)
        // even after the highlight was finished.
        let annotations = model.annotationController
        if annotations.barVisible, annotations.tool != .select { return }
        // A click on an existing mark (`markAt`) opens the "Change"/"Remove"
        // bar (`mouseDown(with:)` further down in `MarksOverlayView.swift`);
        // it is never a text-selection gesture, so it does not touch the
        // multi-selection.
        guard markAt(point) == nil else { return }

        guard event.modifierFlags.contains(.command) else {
            // A click without ⌘ cancels the selection: empty the
            // accumulated pieces BEFORE PDFView replaces its native
            // selection with the new/empty one.
            if !model.multiSelectionPieces.isEmpty { model.clearMultiSelection() }
            return
        }
        // First ⌘-drag of a sequence: the selection ALREADY present (a plain
        // selection made before pressing ⌘, or none) must be saved as the
        // first piece BEFORE this mouseDown makes it disappear; after this
        // event `pdfView.currentSelection` will be the new one being dragged
        // and the old one would be lost.
        if model.multiSelectionPieces.isEmpty, let existing = pdfView.currentSelection,
           let text = existing.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.multiSelectionPieces.append(existing.copy() as? PDFSelection ?? existing)
        }
        isAccumulatingMultiSelectionGesture = true
    }

    /// Not `private`, same reason as `handleMultiSelectionMouseDown` above.
    func handleMultiSelectionMouseUp(_ event: NSEvent) {
        guard isAccumulatingMultiSelectionGesture else { return }
        isAccumulatingMultiSelectionGesture = false
        guard let model, let pdfView else { return }
        if let newPiece = pdfView.currentSelection, let text = newPiece.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.multiSelectionPieces.append(newPiece.copy() as? PDFSelection ?? newPiece)
        }
        guard !model.multiSelectionPieces.isEmpty else { return }
        // Recompose ALL the pieces into a single `PDFSelection`
        // (`PDFSelection.add(_:)`) and reset it as the current selection:
        // PDFKit then highlights EVERY piece with its native drawing, with
        // nothing to draw by hand. This also posts
        // `.PDFViewSelectionChanged` (the standard contract of
        // `setCurrentSelection`), which
        // `MarksOverlaySelectionBar.handleSelectionChanged` already observes,
        // so the bar reconfigures itself in "multi-selection" mode.
        guard let first = model.multiSelectionPieces.first?.copy() as? PDFSelection else { return }
        for piece in model.multiSelectionPieces.dropFirst() { first.add(piece) }
        pdfView.setCurrentSelection(first, animate: false)
    }
}
