import Testing
import CoreGraphics
@testable import LelePdf

/// The sidebar now has a preferred/draggable width like the right panel,
/// instead of the fixed constant `DSMetrics.sidebarWidth`. These tests cover
/// the pure formula, separate from the SwiftUI composition (same principle as
/// `ChatButtonLayoutTests`).
@Suite("WindowLayoutMath · sidebar width")
struct WindowLayoutMathTests {
    @Test("with enough space the sidebar uses the preferred width")
    func usesPreferredSidebarWidth() {
        let result = WindowLayoutMath.compute(
            totalWidth: 1400,
            sidebarVisible: true,
            rightPanelVisible: true,
            preferredSidebarWidth: 300,
            preferredRightPanelWidth: 392
        )
        #expect(result.sidebarWidth == 300)
    }

    @Test("the sidebar's preferred width is clamped to 200...360")
    func clampsSidebarWidthToRange() {
        let tooNarrow = WindowLayoutMath.compute(
            totalWidth: 1400, sidebarVisible: true, rightPanelVisible: true,
            preferredSidebarWidth: 50, preferredRightPanelWidth: 392
        )
        #expect(tooNarrow.sidebarWidth == DSMetrics.sidebarMinWidth)

        let tooWide = WindowLayoutMath.compute(
            totalWidth: 1400, sidebarVisible: true, rightPanelVisible: true,
            preferredSidebarWidth: 900, preferredRightPanelWidth: 392
        )
        #expect(tooWide.sidebarWidth == DSMetrics.sidebarMaxWidth)
    }

    @Test("without an explicit preference the default stays 264 pt (SPEC §5.1)")
    func defaultsToSpecWidth() {
        let result = WindowLayoutMath.compute(
            totalWidth: 1400, sidebarVisible: true, rightPanelVisible: false,
            preferredRightPanelWidth: 392
        )
        #expect(result.sidebarWidth == DSMetrics.sidebarWidth)
    }

    @Test("the center never drops below 440 pt: the right panel shrinks first")
    func rightPanelShrinksBeforeCenterViolatesMinimum() {
        // The two visible 8 pt dividers add up to the three panes.
        let result = WindowLayoutMath.compute(
            totalWidth: 1050, sidebarVisible: true, rightPanelVisible: true,
            preferredSidebarWidth: 264, preferredRightPanelWidth: 392
        )
        #expect(result.sidebarWidth == 264, "the sidebar must not shrink on its own: the right panel goes first")
        #expect(result.rightPanelWidth < 392)
        #expect(result.rightPanelWidth >= DSMetrics.rightPanelMinWidth)
        let center = 1050 - result.sidebarWidth - result.rightPanelWidth - 2 * DSMetrics.paneDividerWidth
        #expect(center >= DSMetrics.minCenterWidth)
    }

    @Test("at the minimum width the dividers take part in the calculation and the PDF keeps 440 pt")
    func minimumWindowIncludesBothDividers() {
        let result = WindowLayoutMath.compute(
            totalWidth: 1040, sidebarVisible: true, rightPanelVisible: true,
            preferredSidebarWidth: 264, preferredRightPanelWidth: 392
        )
        let center = 1040 - result.sidebarWidth - result.rightPanelWidth - 2 * DSMetrics.paneDividerWidth
        #expect(result.sidebarWidth == 264)
        #expect(result.rightPanelWidth == DSMetrics.rightPanelMinWidth)
        #expect(abs(center - DSMetrics.minCenterWidth) < 0.001)
    }

    @Test("if even the right panel at its minimum is not enough, the sidebar closes entirely (it does not shrink)")
    func sidebarClosesEntirelyWhenStillTooTight() {
        // 264 + 440 + 320 (right at minimum) = 1024: with 900 pt total it is still not enough.
        let result = WindowLayoutMath.compute(
            totalWidth: 900, sidebarVisible: true, rightPanelVisible: true,
            preferredSidebarWidth: 264, preferredRightPanelWidth: 392
        )
        #expect(result.sidebarWidth == 0, "the sidebar closes, it does not shrink to an intermediate width")
        #expect(result.rightPanelWidth == DSMetrics.rightPanelMinWidth)
    }

    @Test("a sidebar wider than 264 pt still leaves the center ≥ 440 pt")
    func widerSidebarStillRespectsCenterMinimum() {
        let result = WindowLayoutMath.compute(
            totalWidth: 1040, sidebarVisible: true, rightPanelVisible: true,
            preferredSidebarWidth: 360, preferredRightPanelWidth: 392
        )
        let visibleDividers = (result.sidebarWidth > 0 ? DSMetrics.paneDividerWidth : 0)
            + (result.rightPanelWidth > 0 ? DSMetrics.paneDividerWidth : 0)
        let center = 1040 - result.sidebarWidth - result.rightPanelWidth - visibleDividers
        #expect(center >= DSMetrics.minCenterWidth || result.sidebarWidth == 0)
    }

    // MARK: - Even split between the original PDF and the summary. The
    // requirement: the right panel must be able to reach half and half, so
    // that the PDF does not seem more important. Before this change
    // `rightPanelMaxWidth` was fixed at 520 pt, a static cap that at NO
    // practical window width let the right panel reach half: at 1400 pt (with
    // the sidebar visible at 264 pt and the two 8 pt dividers) a true
    // half/half already needs 560 pt. Raised to 900 pt in `DSMetrics`, the
    // real limit protecting the PDF remains `minCenterWidth` (440 pt, SPEC
    // §5.1, unchanged) through `availableForRight`; these tests verify that
    // half/half is NOW reachable at common widths, without the center ever
    // dropping below 440 pt.
    @Test("the right panel reaches half of the window at common widths, with the sidebar visible")
    func fiftyFiftySplitReachableAtCommonWindowWidths() {
        // 1400/1600 pt: common external monitor; 1728 pt: 16" MacBook Pro at
        // "more space"; 1920 pt: Full HD monitor.
        let commonWidths: [CGFloat] = [1400, 1600, 1728, 1920]
        let sidebar = DSMetrics.sidebarWidth
        let dividers = 2 * DSMetrics.paneDividerWidth
        for total in commonWidths {
            let idealHalf = (total - sidebar - dividers) / 2
            let result = WindowLayoutMath.compute(
                totalWidth: total, sidebarVisible: true, rightPanelVisible: true,
                preferredSidebarWidth: sidebar, preferredRightPanelWidth: idealHalf
            )
            #expect(
                result.rightPanelWidth == idealHalf,
                "at \(total) pt the right panel should be able to reach \(idealHalf) pt (half/half): found \(result.rightPanelWidth), cut off by a limit that is too low"
            )
            let center = total - result.sidebarWidth - result.rightPanelWidth - dividers
            #expect(
                abs(center - result.rightPanelWidth) < 1,
                "at \(total) pt the PDF (\(center) pt) and the summary (\(result.rightPanelWidth) pt) should be almost identical, not one larger than the other"
            )
            #expect(center >= DSMetrics.minCenterWidth, "the PDF must never drop below 440 pt (SPEC §5.1) even when the right panel grows")
        }
    }

    @Test("without a sidebar the right panel reaches half even at a smaller window width")
    func fiftyFiftyWithoutSidebarAtSmallerWidth() {
        let total: CGFloat = 1200
        let idealHalf = (total - DSMetrics.paneDividerWidth) / 2
        let result = WindowLayoutMath.compute(
            totalWidth: total, sidebarVisible: false, rightPanelVisible: true,
            preferredRightPanelWidth: idealHalf
        )
        #expect(result.sidebarWidth == 0)
        #expect(result.rightPanelWidth == idealHalf)
        let center = total - result.rightPanelWidth - DSMetrics.paneDividerWidth
        #expect(abs(center - result.rightPanelWidth) < 1)
        #expect(center >= DSMetrics.minCenterWidth)
    }

    @Test("the DSMetrics.rightPanelMaxWidth cap is no longer the bottleneck at 1400 pt (regression of the old 520 pt limit)")
    func rightPanelMaxWidthIsNoLongerTheBottleneckAtModestWidths() {
        // Minimal direct proof of the reported regression: the old
        // `rightPanelMaxWidth` (520 pt) was NARROWER than half/half already at
        // the most modest of the common widths tried above (1400 pt, where
        // 560 pt are needed), so the static cap, not the dynamic computation
        // in `WindowLayoutMath`, was the cause of the bug.
        #expect(DSMetrics.rightPanelMaxWidth > 560, "the cap must allow at least half/half at a 1400 pt window")
    }
}
