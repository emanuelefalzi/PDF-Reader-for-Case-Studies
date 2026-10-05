import AppKit

/// "Scrolling downward" space common to both sides (SPEC §5.8): y = 0 at the
/// top of the scrollable content, growing downward, independent of how
/// AppKit actually represents the underlying `documentView` (flipped or
/// not). Used both to build the segments (`AlignmentBuilder`, from the PDF's
/// page coordinates and the right panel's measured rectangles) and by
/// `ScrollSyncCoordinator` to read/set the scroll position: the same
/// convention on both sides, so `AlignmentModel` never needs to know which
/// `NSScrollView` it is looking at.
///
/// The PDF's `documentView` (PDFKit's, not ours) is not guaranteed to be
/// flipped: `isFlipped` is read at runtime instead of assumed. The right
/// panel's `documentView` is ours (`RewriteFlippedHostingView`, in
/// `RewriteScrollHost.swift`) and forced flipped on purpose so it is already
/// in this same space with no inversions.
@MainActor
enum DocumentSpace {
    /// Top (scrolling downward) and height of the visible part of
    /// `scrollView`, in document space (it does not change while scrolling,
    /// only with zoom/resizing/new layout).
    static func visibleTopDown(_ scrollView: NSScrollView) -> (top: CGFloat, height: CGFloat)? {
        guard let documentView = scrollView.documentView else { return nil }
        let visible = scrollView.contentView.bounds
        if documentView.isFlipped {
            return (visible.minY, visible.height)
        }
        let docHeight = documentView.bounds.height
        return (docHeight - visible.maxY, visible.height)
    }

    /// COMMON reading line for both sides, in window coordinates: at 30%
    /// (`fraction`) of the PDF's visible part, and at the SAME window height
    /// in the panel. SPEC §5.8 puts it "at 30% of the visible height, on
    /// both sides", but the two sides have different headers (page/zoom bar
    /// above the PDF, the panel's header) and therefore two "30%"s at
    /// different window heights: a systematic offset of 22 pt was measured.
    /// Returns, for each side, the distance from the top of the visible part
    /// in units of THAT side's document space (PDFKit scales the clip view's
    /// `bounds` with zoom: a window point is not a document point). Without
    /// a common window, 30% of each.
    static func readingLineOffsets(pdf: NSScrollView, panel: NSScrollView, fraction: CGFloat) -> (pdf: CGFloat, panel: CGFloat)? {
        let pdfClip = pdf.contentView
        let panelClip = panel.contentView
        guard pdfClip.bounds.height > 0, panelClip.bounds.height > 0 else { return nil }
        let fallback = (pdfClip.bounds.height * fraction, panelClip.bounds.height * fraction)
        guard let window = pdf.window, panel.window === window else { return fallback }
        let pdfRect = pdfClip.convert(pdfClip.bounds, to: nil)
        let panelRect = panelClip.convert(panelClip.bounds, to: nil)
        guard pdfRect.height > 0, panelRect.height > 0 else { return fallback }
        // Window coordinates: y pointing up. Reading line at `fraction`
        // from the TOP of the PDF's visible part.
        let lineY = pdfRect.maxY - pdfRect.height * fraction
        let panelDistanceFromTop = min(max(panelRect.maxY - lineY, 0), panelRect.height)
        // PDF side: `fraction` of the visible part is the same fraction in
        // document space (the scale is uniform). Panel side: the distance in
        // the window, brought into its document space.
        let panelScale = panelClip.bounds.height / panelRect.height
        return (pdfClip.bounds.height * fraction, panelDistanceFromTop * panelScale)
    }

    /// Total height of the scrollable content, in the same space.
    static func documentHeight(_ scrollView: NSScrollView) -> CGFloat {
        scrollView.documentView?.bounds.height ?? 0
    }

    /// Maximum scroll (the lowest position reachable for the "top" of the
    /// visible part).
    static func maxScrollTopDown(_ scrollView: NSScrollView) -> CGFloat {
        guard let documentView = scrollView.documentView else { return 0 }
        return max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
    }

    /// Scrolls `scrollView` so that the position (document space) `top`
    /// ends up at the top of the visible part, clamped to the scrollable
    /// range. No animation (SPEC §5.8 "every frame and without animation"):
    /// sets the origin directly, as PDFKit itself does internally for real
    /// scrolling.
    @discardableResult
    static func scroll(_ scrollView: NSScrollView, topDownTop top: CGFloat) -> CGFloat {
        guard let documentView = scrollView.documentView else { return 0 }
        let viewportHeight = scrollView.contentView.bounds.height
        let docHeight = documentView.bounds.height
        let maxTop = max(0, docHeight - viewportHeight)
        let clampedTop = min(max(top, 0), maxTop)
        let rawY = documentView.isFlipped ? clampedTop : (docHeight - clampedTop - viewportHeight)
        let origin = NSPoint(x: scrollView.contentView.bounds.origin.x, y: rawY)
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return clampedTop
    }
}
