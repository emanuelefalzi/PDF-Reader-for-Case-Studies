import CoreGraphics

/// Live dragging (move, resize, eraser): `AnnotationOverlayView` calls
/// `begin…`/`live…` on every `mouseDragged` event (direct mutation, no
/// undo/redo or saving on every tick) and `commit…` on `mouseUp` (ONE
/// undo/redo entry for the whole drag: a group drag moves into one undo
/// step). Separate extension to keep files small.
@MainActor
extension AnnotationController {
    // MARK: - Selection (SPEC "Select: ... shows handles; drag moves")

    func selectAnnotation(at point: CGPoint, page: Int) -> Bool {
        guard let hit = AnnotationHitTesting.topmostHit(annotations, page: page, point: point) else {
            selectedId = nil
            return false
        }
        selectedId = hit.id
        return true
    }

    /// Handle hit on the selected annotation, if the point hits it (SPEC
    /// "handles resize").
    func selectedHandle(at point: CGPoint) -> AnnotationHandle? {
        guard let selected else { return nil }
        return AnnotationGeometry.handle(at: point, in: selected.rect.cgRect)
    }

    // MARK: - Move

    func beginMove() {
        dragSnapshot = selected
    }

    /// Direct mutation (does not go through `update`, which would record an
    /// undo/redo operation for every dragged pixel): also moves the points
    /// (pen/polygon/line) together with the box.
    func liveMove(by delta: CGVector) {
        guard let id = selectedId, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].rect = AnnotationRect(AnnotationGeometry.moved(annotations[index].rect.cgRect, by: delta))
        if let points = annotations[index].points {
            annotations[index].points = points.map { AnnotationPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
        }
        if let quads = annotations[index].quads {
            annotations[index].quads = quads.map { AnnotationRect($0.cgRect.offsetBy(dx: delta.dx, dy: delta.dy)) }
        }
        onAnnotationsChanged?()
    }

    func liveResize(handle: AnnotationHandle, to point: CGPoint) {
        guard let id = selectedId, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let newRect = AnnotationGeometry.resize(annotations[index].rect.cgRect, handle: handle, to: point)
        annotations[index].rect = AnnotationRect(newRect)
        onAnnotationsChanged?()
    }

    /// End of drag: if something really changed relative to the
    /// `beginMove()` snapshot, ONE undo/redo entry; otherwise nothing is
    /// recorded (nothing changed, for example a click without a real drag).
    func commitDrag(actionName: String = "Move Annotation") {
        guard let before = dragSnapshot, let id = selectedId, let after = annotations.first(where: { $0.id == id }) else {
            dragSnapshot = nil
            return
        }
        dragSnapshot = nil
        guard after != before else { return }
        // The live mutation already updated `annotations`: we only record
        // the edit (before/after) without reapplying it.
        recordAppliedEdit(AnnotationEdit(annotationId: id, before: before, after: after), actionName: actionName)
        persist()
    }

    // MARK: - Eraser (SPEC "Eraser to delete pen strokes by touching them")

    /// Strokes (pen) or shapes touched during an eraser drag: a single
    /// undo/redo entry for the whole gesture, like the move;
    /// `AnnotationOverlayView` accumulates the touched ids and calls this at
    /// `mouseUp`.
    func eraseAnnotations(ids: [String]) {
        let edits = ids.compactMap { id -> AnnotationEdit? in
            guard let before = annotations.first(where: { $0.id == id }) else { return nil }
            return AnnotationEdit(annotationId: id, before: before, after: nil)
        }
        // `applyGroup`, not one `apply` per id: otherwise erasing several
        // strokes in a single eraser drag created one undo/redo entry per
        // stroke, contradicting the comment above ("a single entry ... for
        // the whole gesture").
        applyGroup(edits, actionName: "Eraser")
    }
}
