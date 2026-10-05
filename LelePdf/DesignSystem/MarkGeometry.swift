import CoreGraphics

/// States of a mark (SPEC §5.4): normal, repetition (40% opacity),
/// linked/hover (more vivid tone, stroke +1 pt), selected (M7, not yet
/// used in M5b but already modeled so the signature need not change later).
enum MarkState: Sendable, Equatable {
    case normal, repetition, linked, hover, selected
}

/// Pure geometry of the 4 marks (SPEC §5.4), shared by
/// `Reader/MarksOverlayView.swift` (PDF) and `Rewrite/MarkedTextView.swift`
/// (rewritten text). CoreGraphics only: no dependency on AppKit/PDFKit,
/// so it is testable without a graphics host (SPEC M5b deliverable 7
/// "overlay geometry helpers").
enum MarkGeometry {
    static let rectCornerRadius: CGFloat = 4
    static let underlineWidth: CGFloat = 2
    static let circleInset: CGFloat = 3
    static let arrowheadLength: CGFloat = 6
    static let arrowheadHalfWidth: CGFloat = 4
    /// Margin bar (SPEC §5.5): 3 pt capsule, offset from the page's left
    /// edge, in the subject's color (no longer a fixed accent; reported by
    /// the user: "the blue bar... doesn't use the subject color").
    static let marginBarWidth: CGFloat = 3
    static let marginBarOffset: CGFloat = 10
    /// Wider bar for the "focused" block (under the mouse, on the PDF or on
    /// the card, or at the reading position); see
    /// `DocumentModel.currentFocusedBlockId`. Width alone was not enough for
    /// the user to understand the link ("it's not clear that it's the one
    /// highlighting the paragraph"), so an arrow/marker
    /// (`MarksOverlayDrawing.drawMarginBars`) and a faint band behind the
    /// lines (`ParagraphFocusOverlay`) were added.
    static let marginBarWidthFocused: CGFloat = 5
    /// Length/half-width of the arrow marker in the margin, shown only when
    /// the block is truly under the mouse (not just the reading position);
    /// it points exactly at the page edge.
    static let marginMarkerSize: CGFloat = 5

    /// Opacity per state (SPEC §5.4: "Repetition ... at 40% opacity").
    static func opacity(for state: MarkState) -> Double {
        switch state {
        case .repetition: 0.4
        case .linked: 0.65
        default: 1.0
        }
    }

    /// Extra stroke thickness per state (SPEC "stroke +1 pt"; increased after
    /// a real report from the user, "hover on the words is not very clear";
    /// see `fillDarkenFraction(for:)`: hover used to be almost
    /// indistinguishable from normal because opacity is full in both states,
    /// SPEC §5.4, and only the +1 pt thickness changed). `.hover`/`.selected`
    /// (the exact mark under the mouse/with the bar open) now sit in the
    /// 1.5-2 pt range requested by the coordinator; `.linked` (the other
    /// occurrences of the same term) stays one step below so it is not
    /// confused with the full state.
    static func strokeBonus(for state: MarkState) -> CGFloat {
        switch state {
        case .linked: 0.75
        case .hover, .selected: 1.75
        default: 0
        }
    }

    /// How much to darken and saturate the color per state (SPEC §5.4/§5.8,
    /// fix for "unclear hover"): opacity alone cannot tell hover from normal
    /// (both at 100%, see `opacity(for:)`), a darker color can, while staying
    /// in the same palette per type (instruction for that session: "don't
    /// change mark colors"; per-subject colors came later). Pure (no AppKit
    /// dependency): the real transformation is `NSColor.darkened(by:)` in
    /// `MarkPalette.swift`, used the same way on both the PDF side and the
    /// rewritten text.
    static func fillDarkenFraction(for state: MarkState) -> CGFloat {
        switch state {
        case .hover, .selected: 0.28
        case .linked: 0.12
        default: 0
        }
    }

    /// Empty ellipse around the word (circle mark), with a margin around the
    /// text/line rectangle.
    static func ellipseRect(around textRect: CGRect, inset: CGFloat = circleInset) -> CGRect {
        textRect.insetBy(dx: -inset, dy: -inset)
    }

    /// Real bug (coordinator screenshot): `NSLayoutManager.
    /// enumerateEnclosingRects` returns the rectangle of the ENTIRE line
    /// (ascent+descent+leading), not just the glyph outlines, so an ellipse
    /// drawn around that rectangle with `ellipseRect(around:)` spills into the
    /// lines above/below, more so the tighter the line spacing. This
    /// vertically centers a height equal to the font (without leading) inside
    /// the received line rectangle, then applies the ellipse with a reduced
    /// margin, never more than half the line spacing (requirement: "hug the word
    /// ... clipped to not exceed half the line spacing vertically"), so two
    /// circles on consecutive lines cannot touch/overlap. Pure (no AppKit
    /// dependency; `glyphHeight` is already computed by the caller with
    /// `NSFont.ascender - descender`): same choice as `MarkGeometry` in
    /// general.
    static func circleGlyphRect(lineRect: CGRect, glyphHeight: CGFloat, lineSpacing: CGFloat, padding: CGFloat = circleInset) -> CGRect {
        let clampedGlyphHeight = min(max(1, glyphHeight), lineRect.height)
        let extra = max(0, lineRect.height - clampedGlyphHeight)
        let tight = lineRect.insetBy(dx: 0, dy: extra / 2)
        let clampedPadding = min(padding, max(0, lineSpacing / 2))
        return tight.insetBy(dx: -clampedPadding, dy: -clampedPadding)
    }

    /// Rounded rectangle of the "concept" mark, slightly wider than the
    /// underlying text.
    static func rectFillRect(around textRect: CGRect, inset: CGFloat = 1.5) -> CGRect {
        textRect.insetBy(dx: -inset, dy: -inset)
    }

    /// Midpoint of a line's baseline, where to draw the underline
    /// (action/consequence mark), a few points below the line itself.
    static func underlineY(for textRect: CGRect, gap: CGFloat = 2) -> CGFloat {
        textRect.minY - gap
    }

    /// Rectangle of the margin bar (SPEC §5.5): fixed x in the page's left
    /// margin, y over the block's vertical extent on that page. `width`
    /// defaults to `marginBarWidth`; the focused block passes
    /// `marginBarWidthFocused`.
    static func marginBarRect(pageMinX: CGFloat, minY: CGFloat, maxY: CGFloat, width: CGFloat = marginBarWidth) -> CGRect {
        CGRect(x: pageMinX - marginBarOffset, y: minY, width: width, height: max(0, maxY - minY))
    }

    /// Path (as a sequence of points) of an arrow from `start` to `end`:
    /// the line plus the two segments of the head (SPEC §5.4 "ending in an
    /// arrowhead"). Meant to be drawn with
    /// `CGContext.strokeLineSegments` or a `CGMutablePath`.
    static func arrowheadPoints(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.0001 else { return [start, end] }
        let ux = dx / length
        let uy = dy / length
        // Perpendicular normal, for the two "wings" of the head.
        let nx = -uy
        let ny = ux
        let backX = end.x - ux * arrowheadLength
        let backY = end.y - uy * arrowheadLength
        let wing1 = CGPoint(x: backX + nx * arrowheadHalfWidth, y: backY + ny * arrowheadHalfWidth)
        let wing2 = CGPoint(x: backX - nx * arrowheadHalfWidth, y: backY - ny * arrowheadHalfWidth)
        return [wing1, end, wing2]
    }

    /// True if `point` falls in any of the rectangles (hit-testing of hover
    /// and click on the PDF marks, `MarksOverlayHover`).
    static func hitTest(_ point: CGPoint, rects: [CGRect]) -> Bool {
        rects.contains { $0.contains(point) }
    }

    /// Rectangle enclosing all the given rectangles (margin bar and block
    /// rectangle for hover, `MarksOverlayView.blockHitItems`). `nil` if the
    /// list is empty.
    static func boundingRect(of rects: [CGRect]) -> CGRect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() { result = result.union(rect) }
        return result
    }
}

/// Full identity of a hover (reported by the user: "when I hover over an
/// underlined word, many more get highlighted"): `termId` is not enough,
/// since it is the document's concept registry (`Repetitions.swift`) and
/// by construction can appear as a REAL mark in several independent
/// blocks, not only as a repetition, so a shared `termId` alone does not
/// identify "the same mark" at all. Only `markId` **together with**
/// `blockId` does: `markId` alone is a block-local numbering
/// (`{{mX|...}}` restarts at m1 in every block), never unique across the
/// whole document.
struct HoverIdentity: Sendable, Equatable {
    var termId: String?
    var markId: String?
    var blockId: String?
}

/// Pure selection of the linked state, shared between the PDF and the
/// rewritten text (SPEC §5.8).
enum HoverLinking {
    /// - `markId`/`blockId`: identity of the mark whose state is computed.
    /// - `hoveredMarkId`/`hoveredBlockId`: exact target of the word-by-word
    ///   hover (PDF <-> rewrite): a mark matches it ONLY if both match, "the
    ///   mark with the same id in the rewrite" (SPEC §5.8), nothing else,
    ///   never another occurrence of the same term elsewhere in the document.
    /// - `hoveredTermId`, when `hoveredMarkId` is `nil`: hover from a map
    ///   node (SPEC §5.3 "the matching marks light up", plural); there
    ///   aggregating over the whole `termId` is intended, not a bug: a node
    ///   represents the concept, not one specific mark.
    static func state(
        markId: String?, blockId: String?, termId: String, isRepetition: Bool,
        hoveredMarkId: String?, hoveredBlockId: String?, hoveredTermId: String?
    ) -> MarkState {
        if let hoveredMarkId, let markId, markId == hoveredMarkId, blockId == hoveredBlockId {
            return .hover
        }
        if hoveredMarkId == nil, let hoveredTermId, termId == hoveredTermId {
            return .hover
        }
        return isRepetition ? .repetition : .normal
    }
}
