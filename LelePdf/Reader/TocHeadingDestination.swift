import CoreGraphics

/// Destination point (page space) used to bring a contents heading to the
/// top of the screen. The user reported that clicking a heading should land
/// on the page with that heading at the top of the viewport. Pure, with no
/// dependency on PDFKit/AppKit, so it is testable without a graphical host,
/// the same principle as `MarkGeometry`.
enum TocHeadingDestination {
    /// Margin above the heading (SPEC "8-12 pt"): a small gap instead of
    /// sticking it to the exact edge of the screen.
    static let topMargin: CGFloat = 10

    /// `pageY` is the top edge of the heading (page space, y grows upward,
    /// same convention as `TocEntry.pageY`); `pageHeight` is the page height
    /// (`mediaBox`). The result never exceeds the top of the page (a heading
    /// already very close to the top must not push the point off the page).
    static func point(pageY: Double, pageHeight: CGFloat, pageMinX: CGFloat = 0) -> CGPoint {
        let y = min(CGFloat(pageY) + topMargin, pageHeight)
        return CGPoint(x: pageMinX, y: y)
    }
}
