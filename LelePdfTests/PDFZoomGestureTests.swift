import Foundation
import Testing
@testable import LelePdf

/// `PDFZoomGesture`: the pure math of zooming with ⌃+wheel/pinch, requested to
/// behave "like in Word". Deliberately no `NSEvent`/PDFKit here (brief: "a pure
/// unit-level zoom model... that you can test without NSEvent"); the part that
/// touches the real view is in `PDFWheelZoomApplicationTests.swift`.
@Suite("PDFZoomGesture (pure math)")
struct PDFZoomGestureTests {
    // MARK: - Delta → new scale, clamped

    @Test("a positive delta increases the scale, a negative one decreases it")
    func deltaSignChangesDirection() {
        let up = PDFZoomGesture.newScale(currentScale: 1, rawDelta: 50, minScale: 0.1, maxScale: 20)
        let down = PDFZoomGesture.newScale(currentScale: 1, rawDelta: -50, minScale: 0.1, maxScale: 20)
        #expect(up > 1)
        #expect(down < 1)
    }

    @Test("clamped at the minimum and maximum, never exceeds them")
    func clampedAtBounds() {
        let hugeUp = PDFZoomGesture.newScale(currentScale: 1, rawDelta: 100_000, minScale: 0.1, maxScale: 20)
        let hugeDown = PDFZoomGesture.newScale(currentScale: 1, rawDelta: -100_000, minScale: 0.1, maxScale: 20)
        #expect(hugeUp == 20)
        #expect(hugeDown == 0.1)
    }

    @Test("a zero delta leaves the scale unchanged")
    func zeroDeltaIsNoOp() {
        #expect(PDFZoomGesture.newScale(currentScale: 1.4, rawDelta: 0, minScale: 0.1, maxScale: 20) == 1.4)
    }

    @Test("same absolute delta: doubling and halving are inverses of each other (exponential scale, no jumps)")
    func exponentialIsSymmetric() {
        let scaleUp = PDFZoomGesture.newScale(currentScale: 1, rawDelta: 30, minScale: 0.01, maxScale: 100)
        let backDown = PDFZoomGesture.newScale(currentScale: scaleUp, rawDelta: -30, minScale: 0.01, maxScale: 100)
        #expect(abs(backDown - 1) < 0.0001)
    }

    @Test("a burst of small deltas equals a single summed delta (continuity)")
    func burstOfSmallDeltasMatchesSingleLargeDelta() {
        var scale: CGFloat = 1
        for _ in 0 ..< 10 {
            scale = PDFZoomGesture.newScale(currentScale: scale, rawDelta: 5, minScale: 0.01, maxScale: 100)
        }
        let singleStep = PDFZoomGesture.newScale(currentScale: 1, rawDelta: 50, minScale: 0.01, maxScale: 100)
        #expect(abs(scale - singleStep) < 0.0001)
    }

    @Test("degenerate bounds (min ≥ max, current scale ≤ 0) do not produce NaN/infinity: the scale stays the current one")
    func degenerateBoundsAreSafe() {
        #expect(PDFZoomGesture.newScale(currentScale: 1, rawDelta: 10, minScale: 5, maxScale: 5) == 1)
        #expect(PDFZoomGesture.newScale(currentScale: 0, rawDelta: 10, minScale: 0.1, maxScale: 20) == 0)
    }

    // MARK: - Pinch (magnify)

    @Test("pinch applies 1+magnification directly, clamped")
    func magnifyAppliesFractionDirectly() {
        #expect(PDFZoomGesture.newScale(currentScale: 2, magnification: 0.5, minScale: 0.1, maxScale: 20) == 3)
        #expect(PDFZoomGesture.newScale(currentScale: 2, magnification: -0.5, minScale: 0.1, maxScale: 20) == 1)
        #expect(PDFZoomGesture.newScale(currentScale: 2, magnification: 50, minScale: 0.1, maxScale: 20) == 20)
    }

    // MARK: - Anchoring to the cursor ("the point under the cursor stays put")

    @Test("the content point under the cursor stays the same before and after the scale change")
    func anchorPointStaysUnderCursor() {
        let oldOrigin = CGPoint(x: 120, y: 340)
        let mouseViewPoint = CGPoint(x: 60, y: 90) // cursor position in the viewport
        let oldScale: CGFloat = 1
        let newScale: CGFloat = 2

        let newOrigin = PDFZoomGesture.anchoredOrigin(oldOrigin: oldOrigin, mouseViewPoint: mouseViewPoint, oldScale: oldScale, newScale: newScale)

        // The content point under the cursor, BEFORE the scale change.
        let contentBefore = CGPoint(x: oldOrigin.x + mouseViewPoint.x, y: oldOrigin.y + mouseViewPoint.y)
        // The same PAGE point, at the NEW scale (proportional to the (0,0)
        // origin, see the comment on `anchoredOrigin`).
        let samePagePointAtNewScale = CGPoint(x: contentBefore.x * (newScale / oldScale), y: contentBefore.y * (newScale / oldScale))
        // If we scroll to `newOrigin`, the point under the cursor must be
        // exactly that one again.
        let contentAfter = CGPoint(x: newOrigin.x + mouseViewPoint.x, y: newOrigin.y + mouseViewPoint.y)
        #expect(abs(contentAfter.x - samePagePointAtNewScale.x) < 0.0001)
        #expect(abs(contentAfter.y - samePagePointAtNewScale.y) < 0.0001)
    }

    @Test("zooming in and back out with the same anchor returns to the starting origin")
    func zoomInThenOutReturnsToStart() {
        let oldOrigin = CGPoint(x: 50, y: 200)
        let mouseViewPoint = CGPoint(x: 100, y: 150)

        let zoomedOrigin = PDFZoomGesture.anchoredOrigin(oldOrigin: oldOrigin, mouseViewPoint: mouseViewPoint, oldScale: 1, newScale: 2.5)
        let backOrigin = PDFZoomGesture.anchoredOrigin(oldOrigin: zoomedOrigin, mouseViewPoint: mouseViewPoint, oldScale: 2.5, newScale: 1)

        #expect(abs(backOrigin.x - oldOrigin.x) < 0.0001)
        #expect(abs(backOrigin.y - oldOrigin.y) < 0.0001)
    }

    @Test("cursor at the top-left corner of the viewport (mouseViewPoint = zero): the origin follows only the scale ratio")
    func anchorAtViewportOriginScalesOriginDirectly() {
        let oldOrigin = CGPoint(x: 40, y: 40)
        let newOrigin = PDFZoomGesture.anchoredOrigin(oldOrigin: oldOrigin, mouseViewPoint: .zero, oldScale: 1, newScale: 2)
        #expect(newOrigin == CGPoint(x: 80, y: 80))
    }

    @Test("invalid starting scale (≤ 0): the origin does not change instead of dividing by zero")
    func invalidOldScaleReturnsOldOrigin() {
        let oldOrigin = CGPoint(x: 10, y: 10)
        let newOrigin = PDFZoomGesture.anchoredOrigin(oldOrigin: oldOrigin, mouseViewPoint: CGPoint(x: 5, y: 5), oldScale: 0, newScale: 2)
        #expect(newOrigin == oldOrigin)
    }
}
