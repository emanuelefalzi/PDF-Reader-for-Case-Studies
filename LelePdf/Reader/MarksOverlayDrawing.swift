import AppKit
@preconcurrency import PDFKit

/// Rendering identity shared by the two marks overlays. `markId` is unique
/// only within a block, not across the whole document: including `blockId`
/// keeps two `m1` rectangles from different blocks from sharing fade or
/// selected state.
enum MarkOverlayState {
    static func fadeIdentifier(for item: PageMarkItem, pageIndex: Int, offset: Int) -> String {
        item.markId.map { "\(item.blockId ?? "")|\($0)" }
            ?? "rep-\(item.termId)-\(pageIndex)-\(offset)"
    }

    static func isSelected(_ item: PageMarkItem, markId: String?, blockId: String?) -> Bool {
        item.markId != nil && item.markId == markId && item.blockId == blockId
    }
}

/// The actual drawing of the marks and of the margin bar (SPEC §5.4, §5.5):
/// an extension kept separate from `MarksOverlayView.swift` only to keep
/// files at or under ~12 KB.
@MainActor
extension MarksOverlayView {
    /// Draws all the marks (and repetitions) of `page`. Returns `true` if at
    /// least one mark is still fading (so another redraw can be scheduled
    /// shortly).
    func drawMarks(page: PDFPage, pageIndex: Int, model: DocumentModel, pdfView: PDFView, context: CGContext) -> Bool {
        // Same per-page cache as the hover hit test (`hitItems(forPage:)`),
        // so every real redraw repopulates it and the next hover finds it
        // already ready: a single `PDFView.convert` per mark per FRAME, not
        // once for drawing and once more for every mouse event.
        let entries = hitItems(forPage: pageIndex)
        var stillFading = false
        for (offset, entry) in entries.enumerated() {
            let item = entry.item
            let fadeId = MarkOverlayState.fadeIdentifier(for: item, pageIndex: pageIndex, offset: offset)
            let fade = item.markId != nil ? fadeOpacity(id: fadeId) : 1.0
            if fade < 1 { stillFading = true }

            // The solid fill of the "concept" mark is drawn by
            // `RectangleMarksOverlay`, a dedicated view above/below this one
            // with a multiply `compositingFilter` against the actual PDF (this
            // view, like every modern `NSView`, has its own `CALayer`:
            // `.multiply` inside its own `CGContext` only blended with the
            // transparent background of ITS buffer, not with the text pixels
            // drawn by the underlying `PDFView`; the user had reported that
            // the solid underline covered the text beneath). Only the actual
            // drawing is skipped here, not the `fade`/`stillFading`
            // computation above, which stays shared (the same fade state for
            // the fill and for everything else).
            guard item.type != .rectangle else { continue }

            // SPEC §5.4 "Selected" (M7, §5.7): a mark whose "Change"/"Remove"
            // bar is still open stays highlighted as selected, regardless of
            // mouse hover; for the other states the logic shared with the
            // right panel applies (M6).
            let state: MarkState
            if MarkOverlayState.isSelected(item, markId: selectedMarkId, blockId: selectedMarkBlockId) {
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

            draw(type: item.type, viewRects: entry.rects, state: state, fadeOpacity: fade, hue: model.colorTheme, context: context)
        }
        return stillFading
    }

    private func draw(type: MarkType, viewRects: [CGRect], state: MarkState, fadeOpacity: Double, hue: MaterialHue, context: CGContext) {
        guard !viewRects.isEmpty else { return }
        let colors = MarkPalette.colors(for: type, hue: hue)
        let alpha = MarkGeometry.opacity(for: state) * fadeOpacity
        let strokeWidth: CGFloat = (type == .underline || type == .arrow ? MarkGeometry.underlineWidth : 1) + MarkGeometry.strokeBonus(for: state)
        // Fix for the unclear hover (SPEC §5.8, reported by the user): the
        // same darkening as the right-panel side (`MarkedNSTextView.
        // drawShape`) and as the rectangle (`RectangleMarksOverlay`). Both
        // sides (PDF and rewrite) must use the same emphasis for the same
        // mark, otherwise "the counterpart on the other side" would look
        // like a different mark.
        let strokeColor = colors.stroke.darkened(by: MarkGeometry.fillDarkenFraction(for: state))

        context.saveGState()
        defer { context.restoreGState() }

        switch type {
        case .rectangle:
            // Never reached by `drawMarks` (filtered out before calling this
            // function): drawn by `RectangleMarksOverlay`. The case is kept
            // only because `MarkType` is exhaustive; see the comment in
            // `drawMarks` for why.
            break
        case .circle:
            for rect in viewRects {
                let path = CGPath(ellipseIn: MarkGeometry.ellipseRect(around: rect), transform: nil)
                context.addPath(path)
                context.setStrokeColor(strokeColor.withAlphaComponent(alpha).cgColor)
                context.setLineWidth(strokeWidth)
                context.strokePath()
            }
        case .underline:
            context.setStrokeColor(strokeColor.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(strokeWidth)
            context.setLineCap(.round)
            for rect in viewRects {
                let y = MarkGeometry.underlineY(for: rect)
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.strokePath()
        case .arrow:
            context.setStrokeColor(strokeColor.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(strokeWidth)
            context.setLineCap(.round)
            for rect in viewRects {
                let y = MarkGeometry.underlineY(for: rect)
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.strokePath()
            // Arrowhead only at the end of the last line (reading order):
            // SPEC "line ... ending in an arrowhead".
            if let last = viewRects.last {
                let y = MarkGeometry.underlineY(for: last)
                let points = MarkGeometry.arrowheadPoints(from: CGPoint(x: last.minX, y: y), to: CGPoint(x: last.maxX, y: y))
                context.setFillColor(strokeColor.withAlphaComponent(alpha).cgColor)
                context.move(to: points[0])
                context.addLine(to: points[1])
                context.addLine(to: points[2])
                context.closePath()
                context.fillPath()
            }
        }
    }

    /// Margin bar of the analyzed blocks (SPEC §5.5): a capsule in the
    /// subject's color (`DSColor`/`MarkPalette`, tone `.t3`, the same as the
    /// card's accent bar, `CardContainer.accentBarColor` in `BlockCardView`,
    /// so both sides really use the SAME color for the SAME link), in the
    /// page's left margin, over the block's vertical extent on that page.
    /// The user found the earlier fixed blue accent (40%/85%) unclear as a
    /// signal for the paragraph being read, so it was replaced with three
    /// distinct levels, all in the subject's hue:
    /// - any analyzed block: a thin, quiet capsule (30%), just to show
    ///   "there is already a summary here", as before but in the right color;
    /// - the block "in focus" (`DocumentModel.currentFocusedBlockId`: under
    ///   the mouse, on the PDF or on a card, otherwise at the reading
    ///   position): a wider, more intense capsule, **plus** the soft band
    ///   behind the lines (`ParagraphFocusOverlay`, same level);
    /// - focus REALLY under the mouse (`model.hoveredBlockId`, not just the
    ///   reading position): besides the capsule, an arrow pointing at the
    ///   page edge, a clear marker so that width/opacity alone do not have
    ///   to carry all the meaning.
    func drawMarginBars(page: PDFPage, pageIndex: Int, model: DocumentModel, pdfView: PDFView, context: CGContext) {
        guard let blocks = model.structure?.blocks else { return }
        let pageMinX = page.bounds(for: .mediaBox).minX
        let color = MarkPalette.nsColor(hue: model.colorTheme, tone: .t3)
        let focusedBlockId = model.currentFocusedBlockId
        let hoveredBlockId = model.hoveredBlockId
        context.saveGState()
        defer { context.restoreGState() }
        for block in blocks where block.pageStart <= pageIndex && pageIndex <= block.pageEnd {
            guard model.analysisController.blockState(block.id) == .analyzed,
                  let rects = block.lineRectsByPage[pageIndex], let union = MarkGeometry.boundingRect(of: rects) else { continue }
            let isFocused = block.id == focusedBlockId
            let isHovered = isFocused && block.id == hoveredBlockId
            let width = isFocused ? MarkGeometry.marginBarWidthFocused : MarkGeometry.marginBarWidth
            let pageRect = MarkGeometry.marginBarRect(pageMinX: pageMinX, minY: union.minY, maxY: union.maxY, width: width)
            let viewRect = pdfView.convert(pageRect, from: page)
            let capsule = CGPath(roundedRect: viewRect, cornerWidth: viewRect.width / 2, cornerHeight: viewRect.width / 2, transform: nil)
            context.addPath(capsule)
            context.setFillColor(color.withAlphaComponent(isHovered ? 0.92 : (isFocused ? 0.6 : 0.3)).cgColor)
            context.fillPath()

            guard isHovered else { continue }
            // Arrow facing the text, with its tip exactly on the page edge
            // (a clear marker in the margin).
            let midY = viewRect.midY
            let markerSize = MarkGeometry.marginMarkerSize
            let marker = CGMutablePath()
            marker.move(to: CGPoint(x: viewRect.maxX, y: midY - markerSize))
            marker.addLine(to: CGPoint(x: viewRect.maxX + markerSize, y: midY))
            marker.addLine(to: CGPoint(x: viewRect.maxX, y: midY + markerSize))
            marker.closeSubpath()
            context.addPath(marker)
            context.setFillColor(color.withAlphaComponent(0.92).cgColor)
            context.fillPath()
        }
    }
}
