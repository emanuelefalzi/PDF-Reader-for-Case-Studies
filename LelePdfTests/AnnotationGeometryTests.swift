import Testing
import CoreGraphics
@testable import LelePdf

/// `AnnotationGeometry` (SPEC §5.13 selection handles and dragging;
/// "move/resize math"). Pure.
@Suite("AnnotationGeometry")
struct AnnotationGeometryTests {
    @Test("normalizedRect always produces non-negative sizes, whatever the drag direction")
    func normalizedRectHandlesAnyDirection() {
        let rect = AnnotationGeometry.normalizedRect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 10, y: 5), constrainSquare: false)
        #expect(rect.width == 40)
        #expect(rect.height == 45)
        #expect(rect.origin == CGPoint(x: 10, y: 5))
    }

    @Test("normalizedRect with ⇧ produces a square")
    func normalizedRectConstrainsSquare() {
        let rect = AnnotationGeometry.normalizedRect(from: .zero, to: CGPoint(x: 30, y: 10), constrainSquare: true)
        #expect(rect.width == rect.height)
        #expect(rect.width == 30)
    }

    @Test("moved translates the rect by the given delta")
    func movedTranslates() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let moved = AnnotationGeometry.moved(rect, by: CGVector(dx: 5, dy: -3))
        #expect(moved == CGRect(x: 15, y: 7, width: 20, height: 20))
    }

    @Test("resize on every handle keeps the opposite side/corner fixed")
    func resizeKeepsOppositeSideFixed() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let resized = AnnotationGeometry.resize(rect, handle: .topRight, to: CGPoint(x: 150, y: 130))
        #expect(resized.minX == 0) // the left side stays fixed
        #expect(resized.minY == 0) // the bottom side stays fixed
        #expect(resized.width == 150)
        #expect(resized.height == 130)
    }

    @Test("resize on the left handle moves only minX")
    func resizeLeftHandleMovesOnlyMinX() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let resized = AnnotationGeometry.resize(rect, handle: .left, to: CGPoint(x: 20, y: 999))
        #expect(resized.minX == 20)
        #expect(resized.maxX == 100)
        #expect(resized.minY == 0)
        #expect(resized.height == 100)
    }

    @Test("handle(at:) finds the nearest handle within tolerance, nil beyond")
    func handleHitTestingWithinTolerance() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(AnnotationGeometry.handle(at: CGPoint(x: 100, y: 100), in: rect) == .topRight)
        #expect(AnnotationGeometry.handle(at: CGPoint(x: 50, y: 100), in: rect) == .top)
        #expect(AnnotationGeometry.handle(at: CGPoint(x: 50, y: 50), in: rect) == nil) // center, no handle
    }

    @Test("boundingBox encloses all the given points")
    func boundingBoxContainsAllPoints() {
        // `CGRect.contains` excludes the max edges (half-open): min/max are
        // checked directly instead of relying on `.contains(_:)` for points that
        // fall exactly on the edge.
        let points = [CGPoint(x: 5, y: 5), CGPoint(x: -5, y: 20), CGPoint(x: 30, y: 0)]
        let box = AnnotationGeometry.boundingBox(of: points)
        for point in points {
            #expect(point.x >= box.minX && point.x <= box.maxX)
            #expect(point.y >= box.minY && point.y <= box.maxY)
        }
    }

    @Test("point-to-segment distance is zero on the segment, positive outside")
    func distanceToSegment() {
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 10, y: 0)
        #expect(AnnotationGeometry.distance(from: CGPoint(x: 5, y: 0), toSegment: a, b) == 0)
        #expect(AnnotationGeometry.distance(from: CGPoint(x: 5, y: 5), toSegment: a, b) == 5)
    }

    // MARK: - "Delete" (X) button

    @Test("the delete button is centered on the top-right corner of the rect")
    func deleteButtonRectIsCenteredOnTopRightCorner() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
        let button = AnnotationGeometry.deleteButtonRect(for: rect)
        #expect(button.midX == rect.maxX)
        #expect(button.midY == rect.maxY)
        #expect(button.width == AnnotationGeometry.deleteButtonDiameter)
        #expect(button.height == AnnotationGeometry.deleteButtonDiameter)
    }

    @Test("hitsDeleteButton is true at the button's center, false far from the corner")
    func hitsDeleteButtonWithinCircleOnly() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
        #expect(AnnotationGeometry.hitsDeleteButton(CGPoint(x: 100, y: 40), rect: rect)) // exactly on the corner
        #expect(!AnnotationGeometry.hitsDeleteButton(CGPoint(x: 50, y: 20), rect: rect)) // center of the rect, far away
        #expect(!AnnotationGeometry.hitsDeleteButton(CGPoint(x: 0, y: 0), rect: rect)) // opposite corner
    }
}
