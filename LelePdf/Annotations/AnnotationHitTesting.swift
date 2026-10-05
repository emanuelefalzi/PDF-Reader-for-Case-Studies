import CoreGraphics

/// Per-kind hit-testing of annotations (SPEC §5.13 "Select: click an
/// annotation to choose it"). Pure: no dependency on AppKit/PDFKit, operates
/// on the saved model in page space.
enum AnnotationHitTesting {
    /// Tolerance for thin strokes (lines, pen, unfilled borders): a click
    /// within this distance of the stroke counts as a hit, as in Preview
    /// (otherwise lines would have no perceptible thickness to click).
    static let strokeTolerance: CGFloat = 6

    static func hitTest(_ annotation: Annotation, point: CGPoint) -> Bool {
        let rect = annotation.rect.cgRect
        switch annotation.kind {
        case .highlight, .underline, .strikeout:
            // Per-line rectangles if present (multi-line), otherwise the
            // bounding box.
            if let quads = annotation.quads, !quads.isEmpty {
                return quads.contains { $0.cgRect.insetBy(dx: -2, dy: -2).contains(point) }
            }
            return rect.insetBy(dx: -2, dy: -2).contains(point)

        case .textbox, .note:
            return rect.insetBy(dx: -2, dy: -2).contains(point)

        case .rectangle, .roundedRectangle, .ellipse, .speechBubble:
            if annotation.fillColor != nil, annotation.fillColor?.alpha ?? 0 > 0 {
                return rect.contains(point)
            }
            return distanceToBorder(of: rect, point: point) <= strokeTolerance

        case .line, .arrow:
            guard let points = annotation.points, points.count >= 2 else { return false }
            return AnnotationGeometry.distance(from: point, toSegment: points[0].cgPoint, points[1].cgPoint) <= strokeTolerance

        case .ink, .polygon:
            guard let points = annotation.points, !points.isEmpty else { return false }
            let polyline = annotation.kind == .polygon ? points.map(\.cgPoint) + [points[0].cgPoint] : points.map(\.cgPoint)
            if annotation.kind == .polygon, annotation.fillColor != nil, annotation.fillColor?.alpha ?? 0 > 0, rect.contains(point) {
                return true
            }
            return AnnotationGeometry.distance(from: point, toPolyline: polyline) <= strokeTolerance

        case .star:
            if annotation.fillColor != nil, annotation.fillColor?.alpha ?? 0 > 0 {
                return rect.contains(point)
            }
            return distanceToBorder(of: rect, point: point) <= strokeTolerance
        }
    }

    /// Distance from a rectangle's border (for unfilled shapes: only the
    /// outline is clickable, not the interior): minimum distance from the
    /// four sides, which holds both from inside and from outside the
    /// rectangle.
    private static func distanceToBorder(of rect: CGRect, point: CGPoint) -> CGFloat {
        let corners = [
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)),
        ]
        return corners.map { AnnotationGeometry.distance(from: point, toSegment: $0.0, $0.1) }.min() ?? .infinity
    }

    /// Topmost annotation (last created, as in Preview "the last one drawn
    /// wins") that contains `point`, filtered by page.
    static func topmostHit(_ annotations: [Annotation], page: Int, point: CGPoint) -> Annotation? {
        annotations.filter { $0.page == page }.last { hitTest($0, point: point) }
    }

    /// Kinds with a "delete" (X) button at the top-right corner: only note
    /// and text box, as explicitly requested ("notes ... also via an x
    /// button"); the other annotations stay deletable only with ⌫/menu, as
    /// in Preview for shapes.
    static let kindsWithDeleteButton: Set<AnnotationKind> = [.note, .textbox]

    /// True if `point` falls on `annotation`'s "delete" button (only for the
    /// `kindsWithDeleteButton` kinds).
    static func hitsDeleteButton(_ annotation: Annotation, point: CGPoint) -> Bool {
        guard kindsWithDeleteButton.contains(annotation.kind) else { return false }
        return AnnotationGeometry.hitsDeleteButton(point, rect: annotation.rect.cgRect)
    }

    /// Among `candidateIds` (typically: the annotation selected and/or under
    /// the mouse) on the same page, the one whose "delete" button is hit by
    /// `point`. "Last one wins" is not needed here: the buttons never
    /// overlap each other in practice (only one selected/hovered element at
    /// a time).
    static func deleteButtonHit(_ annotations: [Annotation], candidateIds: Set<String>, page: Int, point: CGPoint) -> Annotation? {
        guard !candidateIds.isEmpty else { return nil }
        return annotations.first { $0.page == page && candidateIds.contains($0.id) && hitsDeleteButton($0, point: point) }
    }
}
