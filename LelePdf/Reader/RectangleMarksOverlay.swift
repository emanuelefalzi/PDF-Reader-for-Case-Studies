import AppKit
import CoreImage
@preconcurrency import PDFKit

/// Rounded solid fill of the "concept" mark (SPEC §5.4), in a true multiply
/// blend against the PDF underneath. The user reported that, with automatic
/// marking, the solid underline hid the text beneath it instead of letting it
/// show through.
///
/// **Cause**: `MarksOverlayDrawing.draw` set `context.setBlendMode(.multiply)`
/// in `MarksOverlayView`'s `CGContext`, but that view is a separate `NSView`
/// above the `PDFView` (`overlay.frame = pdfView.bounds`,
/// `pdfView.addSubview(overlay)`); every modern `NSView` has its own
/// `CALayer`, composited transparently over those below by Core Animation,
/// not shared with a single `CGContext`. The multiply therefore blended with
/// the transparent background of ITS buffer (equivalent to drawing at full
/// color, since multiplying by a zero alpha leaves the source color
/// unchanged), not with the real text pixels painted by the `PDFView`: the
/// rectangle reached the screen as a solid fill OVER the text instead of
/// under it, multiplied.
///
/// **Fixed** by isolating just the fill in this dedicated child view with
/// `layer.compositingFilter` set to multiply: unlike a filter applied only to
/// a layer's CONTENT, `compositingFilter` (QuartzCore, documented) really
/// blends with what is already composited BELOW it in the same window, the
/// same principle by which Preview draws its own highlighter under the text
/// (PDF `Highlight` annotations use the same "Multiply" convention of the PDF
/// standard). The other 3 marks (circle/underline/arrow: thin strokes, not
/// solid fills; checked by eye, they do not noticeably cover the glyphs)
/// stay drawn normally in `MarksOverlayView`/`MarksOverlayDrawing.swift`.
///
/// Transparent to clicks/hover: all interaction stays on `MarksOverlayView`
/// (`hitTest` here always returns `nil`).
@MainActor
final class RectangleMarksOverlay: NSView {
    weak var model: DocumentModel?
    weak var pdfView: PDFView?
    /// The same fade/selection state as `MarksOverlayView`: read from there
    /// instead of keeping its own copy, otherwise the fill and the
    /// outline/other marks could appear and disappear at slightly different
    /// times.
    weak var host: MarksOverlayView?

    init(model: DocumentModel, pdfView: PDFView) {
        self.model = model
        self.pdfView = pdfView
        super.init(frame: pdfView.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    /// Hit testing of the marks (hover/click) stays on `MarksOverlayView`,
    /// above this view: no event is intercepted here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func invalidate() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        // `pdfView`/`document` are no longer needed directly here:
        // `host?.hitItems(forPage:)` uses them internally and returns `[]` if
        // they are missing, so there is no need to check them in this view
        // as well.
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        let colors = MarkPalette.colors(for: .rectangle, hue: model.colorTheme)
        context.saveGState()
        defer { context.restoreGState() }
        // `PerfProbe`: stage measured by the benchmark harness.
        PerfProbe.measure("overlay.rect.draw") {
        for pageIndex in model.visiblePageRange {
            // Rectangles already converted to view space from the same cache
            // as `MarksOverlayView` (`host`).
            guard let entries = host?.hitItems(forPage: pageIndex) else { continue }
            for (offset, entry) in entries.enumerated() where entry.item.type == .rectangle {
                let item = entry.item
                let fadeId = MarkOverlayState.fadeIdentifier(for: item, pageIndex: pageIndex, offset: offset)
                let fade = item.markId != nil ? (host?.fadeOpacity(id: fadeId) ?? 1) : 1.0
                let state: MarkState
                if MarkOverlayState.isSelected(item, markId: host?.selectedMarkId, blockId: host?.selectedMarkBlockId) {
                    state = .selected
                } else {
                    state = HoverLinking.state(
                        markId: item.markId,
                        blockId: item.blockId,
                        termId: item.termId,
                        isRepetition: item.isRepetition,
                        hoveredMarkId: model.hoveredMarkId,
                        hoveredBlockId: model.hoveredMarkBlockId,
                        hoveredTermId: model.hoveredTermId
                    )
                }
                let alpha = MarkGeometry.opacity(for: state) * fade
                let strokeWidth = 1 + MarkGeometry.strokeBonus(for: state)
                // Fix for the unclear hover (SPEC §5.8, reported by the
                // user): fill/outline darker on hover/linked, not just the
                // +1.5-2pt stroke. Opacity alone stays full in both the normal
                // and hover states (see `MarkGeometry.opacity`), so without a
                // different color the two states were nearly
                // indistinguishable.
                let darken = MarkGeometry.fillDarkenFraction(for: state)
                let fillColor = colors.fill.darkened(by: darken)
                let strokeColor = colors.stroke.darkened(by: darken)
                for rect in entry.rects {
                    let path = CGPath(roundedRect: MarkGeometry.rectFillRect(around: rect), cornerWidth: MarkGeometry.rectCornerRadius, cornerHeight: MarkGeometry.rectCornerRadius, transform: nil)
                    context.addPath(path)
                    context.setFillColor(fillColor.withAlphaComponent(alpha).cgColor)
                    context.fillPath()
                }
                for rect in entry.rects {
                    let path = CGPath(roundedRect: MarkGeometry.rectFillRect(around: rect), cornerWidth: MarkGeometry.rectCornerRadius, cornerHeight: MarkGeometry.rectCornerRadius, transform: nil)
                    context.addPath(path)
                    context.setStrokeColor(strokeColor.withAlphaComponent(alpha).cgColor)
                    context.setLineWidth(strokeWidth)
                    context.strokePath()
                }
            }
        }
        }
    }
}
