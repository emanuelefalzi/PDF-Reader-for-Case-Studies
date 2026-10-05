import AppKit
import CoreImage
@preconcurrency import PDFKit

/// Soft band behind the lines of the paragraph "in focus" (SPEC §5.8): half
/// of the PDF-to-rewrite link the user asked for, after finding it unclear
/// that the blue margin bar is what highlights the paragraph being read on
/// the right. The other half (the margin marker) stays in
/// `MarksOverlayDrawing.drawMarginBars`, in the same `MarksOverlayView`:
/// only the band lives here because, like the fill of the "concept" mark
/// (`RectangleMarksOverlay.swift`, whose technique this view copies), it
/// must stay readable OVER the text, so it needs a true multiply blend
/// against the actual PDF underneath: that takes a dedicated child `NSView`
/// with `layer.compositingFilter`, not a `context.setBlendMode(.multiply)`
/// inside `MarksOverlayView` (which would only blend with the transparent
/// background of ITS OWN buffer, not with the text pixels; the same cause as
/// the concept-fill bug, see the long comment in
/// `RectangleMarksOverlay.swift`).
///
/// Transparent to clicks/hover (`hitTest` always `nil`, like
/// `RectangleMarksOverlay`): it must never intercept native text selection
/// or the events that `MarksOverlayView`/`PDFView` already handle.
@MainActor
final class ParagraphFocusOverlay: NSView {
    weak var model: DocumentModel?
    weak var pdfView: PDFView?

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

    /// Like `RectangleMarksOverlay`: all interaction stays with the `PDFView`
    /// underneath and `MarksOverlayView` above this view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func invalidate() { needsDisplay = true }

    /// Only the block "in focus" (SPEC §5.8): showing the band on EVERY
    /// analyzed block (like the margin capsule, which is quiet on its own)
    /// would reintroduce the same visual noise the user complained about,
    /// just in a different color. Here it must remain a single clear signal,
    /// "you are reading THIS", not a second layer of diffuse underlining.
    override func draw(_ dirtyRect: NSRect) {
        guard let model, let pdfView, let document = pdfView.document,
              let context = NSGraphicsContext.current?.cgContext,
              let blockId = model.currentFocusedBlockId,
              let block = model.structure?.blocks.first(where: { $0.id == blockId }),
              model.analysisController.blockState(blockId) == .analyzed
        else { return }

        // More intense when the block is REALLY under the mouse
        // (`hoveredBlockId`), not just at the current reading position: the
        // same three-level distinction as the margin capsule.
        let isHovered = model.hoveredBlockId == blockId
        let color = MarkPalette.nsColor(hue: model.colorTheme, tone: .t3)
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(color.withAlphaComponent(isHovered ? 0.16 : 0.09).cgColor)
        for pageIndex in model.visiblePageRange where block.pageStart <= pageIndex && pageIndex <= block.pageEnd {
            guard let page = document.page(at: pageIndex), let rects = block.lineRectsByPage[pageIndex] else { continue }
            for rect in rects {
                let viewRect = pdfView.convert(rect, from: page).insetBy(dx: -2, dy: -1)
                let path = CGPath(roundedRect: viewRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
                context.addPath(path)
                context.fillPath()
            }
        }
    }
}
