import AppKit
@preconcurrency import PDFKit

/// "Delete" button (X) on a note/text box, like Preview: "notes must be
/// deletable also via an x button at the top right", visible when the note is
/// selected OR under the mouse. Extension kept separate from
/// `AnnotationOverlayView.swift` to keep files small: hover state (tracking
/// area, same scheme as `Map/MapInteractionLayer.swift`), drawing of the
/// button and dedicated hit-testing, shared by `hitTest`/`mouseDown`
/// (`+Mouse.swift`) and `draw(_:)` (main file). The actual deletion goes
/// through `AnnotationController.delete(id:)`, already undoable (⌘Z,
/// `AnnotationController.apply`/`armSystemUndo`) and persisted in
/// `annotazioni.json` with the same atomic write as the other edits
/// (`AnnotationController.persist()`).
@MainActor
extension AnnotationOverlayView {
    /// Annotations that can currently be "decorated": selected and/or under
    /// the mouse (SPEC "visible when the note is selected OR on mouse
    /// hover"), not all those on the page, to avoid crowding the screen with
    /// buttons.
    private var deleteButtonCandidateIds: Set<String> {
        Set([controller?.selectedId, hoveredId].compactMap { $0 })
    }

    // MARK: - Hover (SPEC "selected OR under the mouse")

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let deleteButtonTrackingArea { removeTrackingArea(deleteButtonTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        deleteButtonTrackingArea = area
    }

    /// Not `private`: called by `stopObserving()` (main file,
    /// `AnnotationOverlayView.swift`: the `private` `selectionObserver`
    /// there requires the full teardown to live in that file, but the
    /// tracking area remains this extension's responsibility). Explicit
    /// removal instead of relying only on `removeFromSuperview()`/view
    /// deallocation: crash fix, AppKit can still call `updateTrackingAreas()`
    /// on this view during a display cycle already in progress when the area
    /// was not removed beforehand.
    func removeDeleteButtonTrackingArea() {
        if let deleteButtonTrackingArea {
            removeTrackingArea(deleteButtonTrackingArea)
            self.deleteButtonTrackingArea = nil
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func updateHover(atViewPoint viewPoint: CGPoint) {
        guard let controller, controller.barVisible, let (page, pagePoint) = pageAndPoint(for: viewPoint) else {
            setHovered(nil)
            return
        }
        let deletable = controller.annotations.filter { AnnotationHitTesting.kindsWithDeleteButton.contains($0.kind) }
        setHovered(AnnotationHitTesting.topmostHit(deletable, page: page, point: pagePoint)?.id)
    }

    private func setHovered(_ id: String?) {
        guard hoveredId != id else { return }
        hoveredId = id
        needsDisplay = true
    }

    // MARK: - Hit-testing (shared by `hitTest`/`mouseDown`, `+Mouse.swift`)

    /// "Decorable" annotation whose delete button is hit by a point in VIEW
    /// space (the one that arrives at `hitTest`/`mouseDown`).
    func deleteButtonHit(atViewPoint viewPoint: CGPoint) -> Annotation? {
        guard let controller, let (page, pagePoint) = pageAndPoint(for: viewPoint) else { return nil }
        return AnnotationHitTesting.deleteButtonHit(controller.annotations, candidateIds: deleteButtonCandidateIds, page: page, point: pagePoint)
    }

    // MARK: - Drawing (called by `draw(_:)` in the main file)

    func drawDeleteButtons(pdfView: PDFView, context: CGContext) {
        guard let controller, controller.barVisible, let document = pdfView.document else { return }
        let candidates = deleteButtonCandidateIds
        guard !candidates.isEmpty else { return }
        for annotation in controller.annotations
        where candidates.contains(annotation.id) && AnnotationHitTesting.kindsWithDeleteButton.contains(annotation.kind) {
            guard let page = document.page(at: annotation.page) else { continue }
            let pageButtonRect = AnnotationGeometry.deleteButtonRect(for: annotation.rect.cgRect)
            drawDeleteButton(in: pdfView.convert(pageButtonRect, from: page), context: context)
        }
    }

    /// Filled circle (the same `DSColor.accent` used elsewhere in the app for
    /// interface accents) with a white X: the same visual principle as
    /// Preview's close button, not a system icon (no dependency on SF
    /// Symbols inside a pure CoreGraphics `draw(_:)`).
    private func drawDeleteButton(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor(DSColor.accent).cgColor)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.addEllipse(in: rect)
        context.drawPath(using: .fillStroke)

        let mark = rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: mark.minX, y: mark.minY))
        context.addLine(to: CGPoint(x: mark.maxX, y: mark.maxY))
        context.move(to: CGPoint(x: mark.minX, y: mark.maxY))
        context.addLine(to: CGPoint(x: mark.maxX, y: mark.minY))
        context.strokePath()
        context.restoreGState()
    }
}
