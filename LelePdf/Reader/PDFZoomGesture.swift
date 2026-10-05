import CoreGraphics
import Foundation

/// Pure math for ⌃+wheel/pinch zoom (requested by the user: Ctrl plus the
/// mouse wheel zooms in or out depending on direction, as it does in Word).
/// There is deliberately no `NSEvent`/PDFKit here: it is testable on its own
/// (`PDFZoomGestureTests.swift`), and the part that touches the real view
/// (`PDFReaderCoordinator+WheelZoom.swift`) is just a thin bridge to these
/// two functions.
enum PDFZoomGesture {
    /// How much one "notch" of `scrollingDeltaY` (points, precise trackpad)
    /// changes the scale. Exponential (`exp`), not linear: a burst of small
    /// events gives continuous zoom proportional to the current scale
    /// (smooth and without jumps) instead of a fixed increment that feels
    /// ever more abrupt as the scale grows. The value was chosen to feel
    /// like Word/Preview on a trackpad (SPEC gives no numeric reference); it
    /// is the only knob to tweak if the speed does not feel right.
    static let wheelSensitivity: CGFloat = 0.0035

    /// As in Word: one notch upward (away from the body) = zoom in. **Not
    /// verifiable on real hardware during development** (no real device was
    /// available): if the direction turns out inverted relative to what the
    /// user expects, this is the ONLY value to change (`true`); nothing else
    /// needs touching.
    static let invertWheelDirection = false

    /// New scale for a raw wheel delta (with the sign of
    /// `invertWheelDirection` already applied by the caller), clamped between
    /// `minScale`/`maxScale`: the same limits `PDFReaderBridge.
    /// zoomIn()/zoomOut()` read from `PDFView.minScaleFactor`/`maxScaleFactor`
    /// (consistent with ⌘+/⌘-/⌘0), so no new thresholds are invented here.
    static func newScale(currentScale: CGFloat, rawDelta: CGFloat, minScale: CGFloat, maxScale: CGFloat) -> CGFloat {
        guard currentScale > 0, maxScale > minScale, minScale > 0 else { return currentScale }
        let factor = exp(rawDelta * wheelSensitivity)
        return clamped(currentScale * factor, minScale: minScale, maxScale: maxScale)
    }

    /// Trackpad pinch (`NSEvent.magnification`): already a direct fractional
    /// change (`1 + magnification`), so `wheelSensitivity` is not needed.
    static func newScale(currentScale: CGFloat, magnification: CGFloat, minScale: CGFloat, maxScale: CGFloat) -> CGFloat {
        guard currentScale > 0, maxScale > minScale, minScale > 0 else { return currentScale }
        return clamped(currentScale * (1 + magnification), minScale: minScale, maxScale: maxScale)
    }

    private static func clamped(_ value: CGFloat, minScale: CGFloat, maxScale: CGFloat) -> CGFloat {
        min(maxScale, max(minScale, value))
    }

    /// New scroll origin (in `NSClipView` space, BEFORE the clamp that
    /// `NSClipView.constrainBoundsRect(_:)` applies on its own) that keeps the
    /// same page point fixed under the cursor, so the zoom anchors on the
    /// pointer position.
    ///
    /// `mouseViewPoint` is the cursor position RELATIVE to the viewport edge
    /// (not to the current scroll origin): the content point under the
    /// cursor, before the scale change, is therefore
    /// `oldOrigin + mouseViewPoint`.
    ///
    /// The content of a `PDFView` in continuous mode scales uniformly about
    /// its origin (0, 0), with no scale-independent margin in the layout
    /// (checked against the SDK's `PDFView.h` and against a real `PDFView`:
    /// see `MarksOverlayZoomGeometryTests.swift`/`PDFZoomRenderExportTests.swift`,
    /// which compare this formula with the real `PDFView.convert(_:from:)` at
    /// several zoom levels), so the same page point moves from
    /// `contentPointOld` to `contentPointOld * (newScale/oldScale)`.
    static func anchoredOrigin(oldOrigin: CGPoint, mouseViewPoint: CGPoint, oldScale: CGFloat, newScale: CGFloat) -> CGPoint {
        guard oldScale > 0 else { return oldOrigin }
        let ratio = newScale / oldScale
        let contentPointOld = CGPoint(x: oldOrigin.x + mouseViewPoint.x, y: oldOrigin.y + mouseViewPoint.y)
        let contentPointNew = CGPoint(x: contentPointOld.x * ratio, y: contentPointOld.y * ratio)
        return CGPoint(x: contentPointNew.x - mouseViewPoint.x, y: contentPointNew.y - mouseViewPoint.y)
    }
}
