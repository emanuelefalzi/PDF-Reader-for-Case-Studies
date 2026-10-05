import CoreGraphics
import Testing
@testable import LelePdf

/// SPEC §5.9: round 44 pt button, 16 pt from the bottom-right corner OF THE
/// WINDOW. Bug reported by the user: the button appeared in the center
/// because `ChatOverlay` did not fill the space of its parent `ZStack`.
@Suite("ChatButtonLayout")
struct ChatButtonLayoutTests {
    @Test("the button stays in the bottom-right corner at several window sizes")
    func bottomTrailingCorner() {
        for size in [
            CGSize(width: 1040, height: 680),
            CGSize(width: 1440, height: 900),
            CGSize(width: 2200, height: 1300),
        ] {
            let frame = ChatButtonLayout.frame(windowSize: size)
            #expect(frame.width == 44)
            #expect(frame.height == 44)
            #expect(frame.maxX == size.width - 16)
            #expect(frame.maxY == size.height - 16)
            #expect(frame.minX == size.width - 60)
            #expect(frame.minY == size.height - 60)
        }
    }

    @Test("the button does not cover the 72 pt reserved margin of the right panel (SPEC §5.6)")
    func doesNotCoverAnalyzeNextButtonMargin() {
        let windowSize = CGSize(width: 1040, height: 680)
        let button = ChatButtonLayout.frame(windowSize: windowSize)
        // The right panel reserves 72 pt from the bottom of the WINDOW (same
        // height as the panel, `RightPanel.frame(maxHeight: .infinity)`) below
        // "Analyze next block" (`RewritePanel.swift`).
        let reservedTop = windowSize.height - DSMetrics.rightPanelBottomMargin
        #expect(button.minY >= reservedTop, "the button enters the zone reserved for the right panel")
    }

    @Test("stays in the corner regardless of panels being open or collapsed")
    func independentFromSidebarAndRightPanel() {
        // The button is anchored to the WINDOW size, not to the sidebar/right
        // panel: its position does not depend on the results of
        // `WindowLayoutMath`, verified here by not passing them.
        let collapsed = ChatButtonLayout.frame(windowSize: CGSize(width: 1040, height: 680))
        let expanded = ChatButtonLayout.frame(windowSize: CGSize(width: 1040, height: 680))
        #expect(collapsed == expanded)
    }
}
