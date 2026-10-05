import Testing
import CoreGraphics
@testable import LelePdf

/// `InkSmoothing` (SPEC §5.13 "Pen ... smoothed stroke", brief M7b
/// deliverable 7 "ink smoothing/simplification: point count reduced,
/// endpoints kept"). Pure logic, no AppKit/PDFKit needed.
@Suite("InkSmoothing")
struct InkSmoothingTests {
    @Test("simplify reduces the points of a nearly straight stroke, keeping the endpoints")
    func simplifyReducesPointCountKeepingEndpoints() {
        // A nearly straight stroke with small deviations (hand jitter) between
        // two distant points: the straight line approximates it within tolerance.
        var points: [CGPoint] = []
        for index in 0 ... 40 {
            let x = CGFloat(index) * 5
            let noise: CGFloat = index.isMultiple(of: 2) ? 0.2 : -0.2
            points.append(CGPoint(x: x, y: noise))
        }
        let simplified = InkSmoothing.simplify(points, tolerance: 1.0)
        #expect(simplified.count < points.count)
        #expect(simplified.first == points.first)
        #expect(simplified.last == points.last)
    }

    @Test("simplify leaves a 2-point stroke alone")
    func simplifyLeavesTwoPointsAlone() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        #expect(InkSmoothing.simplify(points, tolerance: 1) == points)
    }

    @Test("simplify keeps a point that deviates a lot from the chord (a real corner)")
    func simplifyKeepsRealCorners() {
        // An "L": a 90° corner; the middle point's deviation from the direct
        // chord is huge compared to the tolerance, so the vertex stays.
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 50), CGPoint(x: 50, y: 50)]
        let simplified = InkSmoothing.simplify(points, tolerance: 1)
        #expect(simplified.contains(CGPoint(x: 0, y: 50)))
    }

    @Test("smooth does not reduce the point count (it resamples, it does not simplify)")
    func smoothResamplesUpward() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 10)]
        let smoothed = InkSmoothing.smooth(points, samplesPerSegment: 4)
        #expect(smoothed.count > points.count)
        #expect(smoothed.first == points.first)
    }

    @Test("smooth on a single segment stays close to the original endpoints")
    func smoothStaysCloseToEndpoints() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        let smoothed = InkSmoothing.smooth(points)
        // With only 2 points (no neighbours for Catmull-Rom) it stays unchanged.
        #expect(smoothed == points)
    }
}
