import Foundation
import Testing
@testable import LelePdf

/// Pure geometry of the 4 marks (M5b deliverable 7 "overlay geometry helpers").
@Suite("MarkGeometry")
struct MarkGeometryTests {
    @Test("the ellipse is wider than the text rectangle")
    func ellipseInsetAroundText() {
        let text = CGRect(x: 10, y: 10, width: 40, height: 12)
        let ellipse = MarkGeometry.ellipseRect(around: text, inset: 3)
        #expect(ellipse == CGRect(x: 7, y: 7, width: 46, height: 18))
    }

    @Test("the filled rectangle is slightly wider than the text")
    func rectFillAroundText() {
        let text = CGRect(x: 0, y: 0, width: 20, height: 10)
        let rect = MarkGeometry.rectFillRect(around: text, inset: 1.5)
        #expect(rect == CGRect(x: -1.5, y: -1.5, width: 23, height: 13))
    }

    @Test("the margin bar sits to the left of the page, 2pt wide, as tall as the block")
    func marginBarRect() {
        let rect = MarkGeometry.marginBarRect(pageMinX: 60, minY: 100, maxY: 340)
        #expect(rect.width == MarkGeometry.marginBarWidth)
        #expect(rect.origin.x == 60 - MarkGeometry.marginBarOffset)
        #expect(rect.minY == 100)
        #expect(rect.height == 240)
    }

    @Test("the margin bar height never goes negative if minY > maxY")
    func marginBarRectClampsHeight() {
        let rect = MarkGeometry.marginBarRect(pageMinX: 10, minY: 50, maxY: 10)
        #expect(rect.height == 0)
    }

    @Test("the head of a horizontal arrow is symmetric and points right")
    func arrowheadPointsForHorizontalLine() {
        let points = MarkGeometry.arrowheadPoints(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 0))
        #expect(points.count == 3)
        #expect(points[1] == CGPoint(x: 20, y: 0)) // the tip itself is the end point
        let wing1 = points[0], wing2 = points[2]
        #expect(wing1.x == wing2.x) // the two "wings" at the same x (behind the tip)
        #expect(wing1.x == 20 - MarkGeometry.arrowheadLength)
        #expect(wing1.y == -wing2.y) // symmetric above/below the line
    }

    @Test("a degenerate line (start == end) does not crash, returns the two points")
    func arrowheadDegenerateLine() {
        let points = MarkGeometry.arrowheadPoints(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5))
        #expect(points == [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)])
    }

    @Test("opacity: normal is full, repetition is 40%")
    func opacityByState() {
        #expect(MarkGeometry.opacity(for: .normal) == 1.0)
        #expect(MarkGeometry.opacity(for: .repetition) == 0.4)
        #expect(MarkGeometry.opacity(for: .hover) == 1.0)
    }

    @Test("the stroke grows clearly (1.5-2pt) on hover/selected, less when linked")
    func strokeBonusByState() {
        // Reported by the author ("the hover is not very clear"): it used to
        // be only +1pt, which with full opacity in both states (see
        // `opacityByState` above) was hard to see. Now in the requested
        // 1.5-2pt range.
        #expect(MarkGeometry.strokeBonus(for: .normal) == 0)
        #expect(MarkGeometry.strokeBonus(for: .repetition) == 0)
        #expect(MarkGeometry.strokeBonus(for: .linked) > 0)
        #expect(MarkGeometry.strokeBonus(for: .linked) < MarkGeometry.strokeBonus(for: .hover))
        #expect(MarkGeometry.strokeBonus(for: .hover) >= 1.5)
        #expect(MarkGeometry.strokeBonus(for: .hover) <= 2.0)
        #expect(MarkGeometry.strokeBonus(for: .selected) == MarkGeometry.strokeBonus(for: .hover))
    }

    @Test("color darkening: absent in the normal/repetition state, clearly present on hover")
    func fillDarkenFractionByState() {
        #expect(MarkGeometry.fillDarkenFraction(for: .normal) == 0)
        #expect(MarkGeometry.fillDarkenFraction(for: .repetition) == 0)
        #expect(MarkGeometry.fillDarkenFraction(for: .linked) > 0)
        #expect(MarkGeometry.fillDarkenFraction(for: .linked) < MarkGeometry.fillDarkenFraction(for: .hover))
        #expect(MarkGeometry.fillDarkenFraction(for: .hover) == MarkGeometry.fillDarkenFraction(for: .selected))
        #expect(MarkGeometry.fillDarkenFraction(for: .hover) > 0.15) // "noticeably darker", not imperceptible
    }

    @Test("the circle hugs the glyph height, never more than the whole line")
    func circleGlyphRectHugsWord() {
        // A "tall" line (generous line spacing, as in the right panel:
        // lineSpacing 4 + font ~12.5pt ⇒ around 20pt per line) against a
        // typical glyph that is much shorter. Real bug: "the ellipse spills
        // into the lines above/below". The resulting rectangle must be
        // shorter than the whole line and never extend beyond half a line
        // spacing more.
        let lineRect = CGRect(x: 10, y: 100, width: 40, height: 20)
        let glyphHeight: CGFloat = 9
        let lineSpacing: CGFloat = 4
        let rect = MarkGeometry.circleGlyphRect(lineRect: lineRect, glyphHeight: glyphHeight, lineSpacing: lineSpacing)
        #expect(rect.height < lineRect.height, "the circle must be shorter than the whole line: \(rect.height) vs \(lineRect.height)")
        #expect(rect.height <= glyphHeight + lineSpacing, "the added margin must not exceed the line spacing")
        #expect(rect.minY >= lineRect.minY - lineSpacing / 2 - 0.01)
        #expect(rect.maxY <= lineRect.maxY + lineSpacing / 2 + 0.01)
        // The same margin applies horizontally too, as in
        // `ellipseRect(around:inset:)`: only a small, symmetric margin, not a
        // real widening, clamped to half a line spacing like the vertical
        // margin (here lineSpacing/2 = 2, below the default `circleInset` = 3,
        // so that is the margin actually applied).
        let expectedPadding = min(MarkGeometry.circleInset, lineSpacing / 2)
        #expect(rect.minX == lineRect.minX - expectedPadding)
        #expect(rect.width == lineRect.width + 2 * expectedPadding)
    }

    @Test("the circle never exceeds the line height even with a glyph taller than the line itself")
    func circleGlyphRectClampsWhenGlyphTallerThanLine() {
        let lineRect = CGRect(x: 0, y: 0, width: 30, height: 10)
        let rect = MarkGeometry.circleGlyphRect(lineRect: lineRect, glyphHeight: 40, lineSpacing: 4)
        #expect(rect.height <= lineRect.height + 4) // only the margin, never an "exploded" line
    }

    @Test("hit testing: true only if the point falls inside one of the rectangles")
    func hitTestingHelper() {
        let rects = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 20, y: 20, width: 10, height: 10)]
        #expect(MarkGeometry.hitTest(CGPoint(x: 5, y: 5), rects: rects))
        #expect(MarkGeometry.hitTest(CGPoint(x: 25, y: 25), rects: rects))
        #expect(!MarkGeometry.hitTest(CGPoint(x: 15, y: 15), rects: rects))
    }

    @Test("the rectangle enclosing several lines is their union")
    func boundingRectUnion() {
        let rects = [CGRect(x: 0, y: 0, width: 10, height: 5), CGRect(x: 5, y: 10, width: 20, height: 5)]
        #expect(MarkGeometry.boundingRect(of: rects) == CGRect(x: 0, y: 0, width: 25, height: 15))
        #expect(MarkGeometry.boundingRect(of: []) == nil)
    }
}
