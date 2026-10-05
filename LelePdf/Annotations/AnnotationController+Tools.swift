import CoreGraphics

/// Creation of a new annotation per tool (SPEC §5.13): called by
/// `AnnotationOverlayView` at the end of a gesture (mouse release, double
/// click for the polygon, editor close for text box/note). Extension kept
/// separate from `AnnotationController.swift` to keep files small.
@MainActor
extension AnnotationController {
    // MARK: - Box shapes (SPEC "Shapes ... rectangle, rounded rectangle,
    // oval, speech bubble")

    func createShape(kind: AnnotationKind, page: Int, rect: CGRect) {
        guard rect.width > 1 || rect.height > 1 else { return }
        let annotation = Annotation(
            id: nextId(), page: page, kind: kind, color: currentColor.color(), lineWidth: currentWidth.rawValue,
            rect: AnnotationRect(rect)
        )
        create(annotation)
    }

    /// "Box" polygon/star (SPEC "shapes menu ... star"): the star is born
    /// in the dragged box, like the other shapes.
    func createStar(page: Int, rect: CGRect) {
        createShape(kind: .star, page: page, rect: rect)
    }

    // MARK: - Line/arrow (SPEC "line, arrow")

    func createLine(kind: AnnotationKind, page: Int, start: CGPoint, end: CGPoint) {
        guard start != end else { return }
        let rect = AnnotationGeometry.boundingBox(of: [start, end], padding: max(currentWidth.rawValue, 4))
        let annotation = Annotation(
            id: nextId(), page: page, kind: kind, color: currentColor.color(), lineWidth: currentWidth.rawValue,
            rect: AnnotationRect(rect), points: [AnnotationPoint(start), AnnotationPoint(end)]
        )
        create(annotation)
    }

    // MARK: - Multi-vertex polygon (SPEC "polygon")

    func createPolygon(page: Int, points: [CGPoint]) {
        guard points.count >= 3 else { return }
        let rect = AnnotationGeometry.boundingBox(of: points)
        let annotation = Annotation(
            id: nextId(), page: page, kind: .polygon, color: currentColor.color(), lineWidth: currentWidth.rawValue,
            rect: AnnotationRect(rect), points: points.map(AnnotationPoint.init)
        )
        create(annotation)
    }

    // MARK: - Pen (SPEC "Freehand pen ... smoothed stroke")

    /// `rawPoints` in page space, as captured from the drag: simplified
    /// (Ramer–Douglas–Peucker) and smoothed (Catmull-Rom) before saving.
    func createInk(page: Int, rawPoints: [CGPoint], tolerance: CGFloat = 1.2) {
        guard rawPoints.count >= 2 else { return }
        let simplified = InkSmoothing.simplify(rawPoints, tolerance: tolerance)
        let smoothed = InkSmoothing.smooth(simplified)
        let rect = AnnotationGeometry.boundingBox(of: smoothed, padding: max(currentWidth.rawValue, 4))
        let annotation = Annotation(
            id: nextId(), page: page, kind: .ink, color: currentColor.color(), lineWidth: currentWidth.rawValue,
            rect: AnnotationRect(rect), points: smoothed.map(AnnotationPoint.init)
        )
        create(annotation)
    }

    // MARK: - Text box (SPEC "click on the page, type directly")

    /// Empty `text` → no annotation (SPEC "empty → delete").
    func createTextbox(page: Int, rect: CGRect, text: String, fontSize: Double = 13) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let annotation = Annotation(
            id: nextId(), page: page, kind: .textbox, color: currentColor.color(), rect: AnnotationRect(rect),
            text: text, fontSize: fontSize
        )
        create(annotation)
    }

    func updateTextboxText(id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(id: id); return }
        update(id: id, actionName: "Edit Text Box") { $0.text = text }
    }

    // MARK: - Note (SPEC "sticky-note icon ... popover")

    static let noteIconSize: CGFloat = 22

    /// Creates the icon right away (empty note included): the edit popover
    /// opens separately (`AnnotationNotePopover`); if it is still empty when
    /// the popover closes, `updateNoteText` deletes it (SPEC "empty note on
    /// close → delete").
    func createNote(page: Int, at point: CGPoint) -> Annotation {
        let size = Self.noteIconSize
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        let annotation = Annotation(id: nextId(), page: page, kind: .note, color: currentColor.color(), rect: AnnotationRect(rect), text: "")
        create(annotation)
        return annotation
    }

    func updateNoteText(id: String, text: String) {
        guard let existing = annotations.first(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, (existing.text ?? "").isEmpty {
            delete(id: id)
            return
        }
        update(id: id, actionName: "Edit Note") { $0.text = text }
    }

    // MARK: - Text tools (SPEC "Highlight ... drag over the text")

    // Creating highlight/underline/strikethrough NO LONGER goes through
    // here (Preview-style highlighter): `AnnotationTextMarkupCreator.apply`
    // decides on its own whether to mark or unmark
    // (`AnnotationTextMarkupToggle`) and applies the resulting group of
    // edits directly with `applyGroup`, because a single selection can touch
    // several annotations (splits, absorptions) that must undo together with
    // ONE ⌘Z, which a single call to `apply`/`create` (a single
    // `AnnotationEdit`) did not allow.
}
