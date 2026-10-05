import CoreGraphics
import Testing
@testable import LelePdf

/// Pure drag math shared by the sidebar and the right panel.
@Suite("PaneDividerMath")
struct PaneDividerMathTests {
    private let sidebarRange: ClosedRange<CGFloat> = DSMetrics.sidebarMinWidth...DSMetrics.sidebarMaxWidth
    private let rightPanelRange: ClosedRange<CGFloat> = DSMetrics.rightPanelMinWidth...DSMetrics.rightPanelMaxWidth

    @Test("sidebar: dragging right (positive translation) widens")
    func sidebarGrowsRight() {
        let result = PaneDividerMath.resize(base: 264, translation: 30, growsWithPositiveTranslation: true, range: sidebarRange)
        #expect(result == 294)
    }

    @Test("sidebar: dragging left (negative translation) narrows")
    func sidebarShrinksLeft() {
        let result = PaneDividerMath.resize(base: 264, translation: -30, growsWithPositiveTranslation: true, range: sidebarRange)
        #expect(result == 234)
    }

    @Test("right panel: dragging right (positive translation) narrows")
    func rightPanelShrinksRight() {
        let result = PaneDividerMath.resize(base: 392, translation: 30, growsWithPositiveTranslation: false, range: rightPanelRange)
        #expect(result == 362)
    }

    @Test("right panel: dragging left (negative translation) widens")
    func rightPanelGrowsLeft() {
        let result = PaneDividerMath.resize(base: 392, translation: -30, growsWithPositiveTranslation: false, range: rightPanelRange)
        #expect(result == 422)
    }

    @Test("the result always stays within the range, even with huge translations")
    func clampsToRange() {
        let tooSmall = PaneDividerMath.resize(base: 264, translation: -10_000, growsWithPositiveTranslation: true, range: sidebarRange)
        #expect(tooSmall == DSMetrics.sidebarMinWidth)

        let tooBig = PaneDividerMath.resize(base: 264, translation: 10_000, growsWithPositiveTranslation: true, range: sidebarRange)
        #expect(tooBig == DSMetrics.sidebarMaxWidth)

        let rightTooSmall = PaneDividerMath.resize(base: 392, translation: 10_000, growsWithPositiveTranslation: false, range: rightPanelRange)
        #expect(rightTooSmall == DSMetrics.rightPanelMinWidth)

        let rightTooBig = PaneDividerMath.resize(base: 392, translation: -10_000, growsWithPositiveTranslation: false, range: rightPanelRange)
        #expect(rightTooBig == DSMetrics.rightPanelMaxWidth)
    }

    @Test("zero translation changes nothing")
    func zeroTranslationIsNoOp() {
        let result = PaneDividerMath.resize(base: 300, translation: 0, growsWithPositiveTranslation: true, range: sidebarRange)
        #expect(result == 300)
    }
}
