import CoreGraphics

/// Conversions between the model's own types (`AnnotationRect`/`Point`) and
/// CoreGraphics: the single conversion point, so the model stays independent
/// of any change in `CGRect`'s Sendable/Codable status (see
/// `AnnotationModel.swift`).
extension AnnotationRect {
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension AnnotationPoint {
    init(_ point: CGPoint) { self.init(x: point.x, y: point.y) }
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// Resize handle (SPEC §5.13 "selection handles"): eight positions at the
/// corners and sides of the box, like Preview.
enum AnnotationHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// Pure geometry of shapes/handles (SPEC §5.13 "Edit ... handles"); no
/// dependency on AppKit/PDFKit, testable on its own.
enum AnnotationGeometry {
    static let handleSize: CGFloat = 7
    static let handleHitTolerance: CGFloat = 5

    /// Normalized rectangle (origin always at the bottom left, dimensions
    /// never negative) between two dragged points; with `constrainSquare`
    /// the shape becomes a square/circle (SPEC "with ⇧ constrained
    /// proportions").
    static func normalizedRect(from start: CGPoint, to end: CGPoint, constrainSquare: Bool) -> CGRect {
        var end = end
        if constrainSquare {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let side = max(abs(dx), abs(dy))
            end = CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        return CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y).standardized
    }

    /// Position (in page space) of each handle around `rect`.
    static func handlePositions(for rect: CGRect) -> [AnnotationHandle: CGPoint] {
        [
            .topLeft: CGPoint(x: rect.minX, y: rect.maxY),
            .top: CGPoint(x: rect.midX, y: rect.maxY),
            .topRight: CGPoint(x: rect.maxX, y: rect.maxY),
            .right: CGPoint(x: rect.maxX, y: rect.midY),
            .bottomRight: CGPoint(x: rect.maxX, y: rect.minY),
            .bottom: CGPoint(x: rect.midX, y: rect.minY),
            .bottomLeft: CGPoint(x: rect.minX, y: rect.minY),
            .left: CGPoint(x: rect.minX, y: rect.midY),
        ]
    }

    /// Handle hit by `point` (within a tolerance in points), if any.
    static func handle(at point: CGPoint, in rect: CGRect) -> AnnotationHandle? {
        for (handle, position) in handlePositions(for: rect) {
            if abs(point.x - position.x) <= handleHitTolerance, abs(point.y - position.y) <= handleHitTolerance {
                return handle
            }
        }
        return nil
    }

    /// New rectangle from dragging `handle` to `point` (SPEC "handles
    /// resize"): the sides/corners opposite the handle stay fixed.
    static func resize(_ rect: CGRect, handle: AnnotationHandle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomLeft: minX = point.x; minY = point.y
        case .left: minX = point.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// Rectangle moved by `delta` (SPEC "drag" to move a selected
    /// annotation).
    static func moved(_ rect: CGRect, by delta: CGVector) -> CGRect {
        rect.offsetBy(dx: delta.dx, dy: delta.dy)
    }

    /// Diameter of the "delete" button (an X, as in Preview) at the top-right
    /// corner of a note/text box: notes must be deletable also via an x
    /// button at the top right.
    static let deleteButtonDiameter: CGFloat = 16

    /// Rectangle (page space) of the "delete" button, centered ON the
    /// top-right vertex of `rect`: half inside, half outside, like the close
    /// dot of a window or of an edit frame.
    static func deleteButtonRect(for rect: CGRect, diameter: CGFloat = deleteButtonDiameter) -> CGRect {
        let corner = handlePositions(for: rect)[.topRight] ?? CGPoint(x: rect.maxX, y: rect.maxY)
        return CGRect(x: corner.x - diameter / 2, y: corner.y - diameter / 2, width: diameter, height: diameter)
    }

    /// True if `point` falls within the circle of `rect`'s "delete" button.
    static func hitsDeleteButton(_ point: CGPoint, rect: CGRect, diameter: CGFloat = deleteButtonDiameter) -> Bool {
        let buttonRect = deleteButtonRect(for: rect, diameter: diameter)
        return hypot(point.x - buttonRect.midX, point.y - buttonRect.midY) <= diameter / 2
    }

    /// Minimal box containing all the points (used for the pen/polygon's
    /// bounding `rect`).
    static func boundingBox(of points: [CGPoint], padding: CGFloat = 0) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX - padding, y: minY - padding, width: maxX - minX + padding * 2, height: maxY - minY + padding * 2)
    }

    /// Minimum distance from `point` to a segment (for hit-testing lines/
    /// arrows/pen strokes, SPEC "Eraser ... touched strokes").
    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        let projected = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - projected.x, point.y - projected.y)
    }

    /// Minimum distance from `point` to a polyline (pen, polygon).
    static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return points.first.map { hypot(point.x - $0.x, point.y - $0.y) } ?? .infinity }
        var best = CGFloat.infinity
        for index in 0 ..< (points.count - 1) {
            best = min(best, distance(from: point, toSegment: points[index], points[index + 1]))
        }
        return best
    }
}
