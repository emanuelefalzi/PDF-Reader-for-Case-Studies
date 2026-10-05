import AppKit

/// Mouse events for each tool (SPEC §5.13 "Edit ... Eraser"); extension kept
/// separate from `AnnotationOverlayView.swift` to keep files small. Shapes/
/// pen/polygon draw live feedback (`draw(_:)` in the main file) and create
/// the REAL annotation only at the end of the gesture, to avoid flooding the
/// Store with intermediate writes.
@MainActor
extension AnnotationOverlayView {
    override var acceptsFirstResponder: Bool { true }

    /// Without this override (same scheme already used by
    /// `MapInteractionNSView`, `Map/MapInteractionLayer.swift`), the FIRST
    /// click received by a window that is not yet "key" (for example right
    /// after closing the Highlight color dropdown, or the Settings/Summary
    /// Lab window) merely activates the window: AppKit does not deliver it
    /// to `mouseDown(with:)` at all, so it is lost, and the Text/Highlight
    /// tool seems to "do nothing" on the first attempt. Reproduced (by
    /// sending a real `NSEvent` to `NSWindow.sendEvent(_:)` with the window
    /// not "key") in `AnnotationLiveInteractionTests`.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let controller, controller.barVisible else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        // The "delete" button always takes precedence, whatever the active
        // tool (see `+DeleteButton.swift`): `hitTest` already routed the click
        // here on purpose.
        if let target = deleteButtonHit(atViewPoint: viewPoint) {
            controller.delete(id: target.id, actionName: target.kind == .note ? "Delete Note" : "Delete Text Box")
            hoveredId = nil
            needsDisplay = true
            return
        }
        guard let (page, pagePoint) = pageAndPoint(for: viewPoint) else { return }
        window?.makeFirstResponder(self)
        switch controller.tool {
        case .select:
            if let handle = controller.selectedHandle(at: pagePoint) {
                currentResizeHandle = handle
                controller.beginMove()
            } else if controller.selectAnnotation(at: pagePoint, page: page) {
                currentResizeHandle = nil
                controller.beginMove()
                // SPEC "click the icon → popover" also for an already
                // existing note (not only a freshly created one).
                if let selected = controller.selected, selected.kind == .note, event.clickCount >= 1 {
                    presentNotePopover(for: selected)
                }
            }
            currentDragStartPoint = pagePoint
            needsDisplay = true

        case .eraser:
            currentErasedIds = []
            eraseAt(pagePoint, page: page)

        case .rectangle, .roundedRectangle, .ellipse, .speechBubble, .star:
            currentDragStartPage = page
            currentDragStartPoint = pagePoint

        case .line, .arrow:
            currentDragStartPage = page
            currentDragStartPoint = pagePoint

        case .ink:
            currentDragStartPage = page
            resetInk()
            appendInkPoint(pagePoint)

        case .polygon:
            if let existingPage = currentPolygonPage, existingPage != page { resetPolygon() }
            appendPolygonPoint(pagePoint, page: page)
            if event.clickCount >= 2, currentPolygonPoints.count >= 3 {
                controller.createPolygon(page: page, points: currentPolygonPoints)
                resetPolygon()
            }

        case .textbox:
            beginTextboxEditing(page: page, origin: pagePoint)

        case .note:
            let annotation = controller.createNote(page: page, at: pagePoint)
            presentNotePopover(for: annotation)

        case .highlight, .underline, .strikeout:
            beginTextMarkupDrag(page: page, point: pagePoint)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let (page, pagePoint) = pageAndPoint(for: convert(event.locationInWindow, from: nil)) else { return }
        let constrainSquare = event.modifierFlags.contains(.shift)
        switch controller.tool {
        case .select:
            if let handle = currentResizeHandle {
                controller.liveResize(handle: handle, to: pagePoint)
            } else if controller.selectedId != nil, let start = currentDragStartPoint {
                controller.liveMove(by: CGVector(dx: pagePoint.x - start.x, dy: pagePoint.y - start.y))
                currentDragStartPoint = pagePoint
            }
        case .eraser:
            eraseAt(pagePoint, page: page)
        case .rectangle, .roundedRectangle, .ellipse, .speechBubble, .star:
            guard let start = currentDragStartPoint else { return }
            setLiveShapeRect(AnnotationGeometry.normalizedRect(from: start, to: pagePoint, constrainSquare: constrainSquare))
        case .line, .arrow:
            guard let start = currentDragStartPoint else { return }
            setLiveLinePoints((start, pagePoint))
        case .ink:
            appendInkPoint(pagePoint)
        case .highlight, .underline, .strikeout:
            updateTextMarkupDrag(page: page, point: pagePoint)
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        let location = pageAndPoint(for: convert(event.locationInWindow, from: nil))
        let constrainSquare = event.modifierFlags.contains(.shift)
        switch controller.tool {
        case .select:
            controller.commitDrag()
        case .eraser:
            controller.eraseAnnotations(ids: Array(currentErasedIds))
            currentErasedIds = []
        case .rectangle, .roundedRectangle, .ellipse, .speechBubble, .star:
            if let page = currentDragStartPage, let start = currentDragStartPoint, let end = location?.point {
                controller.createShape(kind: controller.tool.kind ?? .rectangle, page: page, rect: AnnotationGeometry.normalizedRect(from: start, to: end, constrainSquare: constrainSquare))
            }
            setLiveShapeRect(nil)
        case .line, .arrow:
            if let page = currentDragStartPage, let start = currentDragStartPoint, let end = location?.point {
                controller.createLine(kind: controller.tool.kind ?? .line, page: page, start: start, end: end)
            }
            setLiveLinePoints(nil)
        case .ink:
            if let page = currentDragStartPage { controller.createInk(page: page, rawPoints: currentInkPoints) }
            resetInk()
        case .highlight, .underline, .strikeout:
            finishTextMarkupDrag(end: location)
        default:
            break
        }
        currentDragStartPoint = nil
        currentDragStartPage = nil
        currentResizeHandle = nil
    }

    override func keyDown(with event: NSEvent) {
        guard let controller, controller.barVisible else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Backspace / Forward Delete
            controller.deleteSelected()
            return
        }
        if event.keyCode == 53 { // Esc: cancels the polygon in progress.
            resetPolygon()
            return
        }
        super.keyDown(with: event)
    }

    private func eraseAt(_ point: CGPoint, page: Int) {
        guard let controller, let hit = AnnotationHitTesting.topmostHit(controller.annotations, page: page, point: point) else { return }
        currentErasedIds.insert(hit.id)
    }
}
