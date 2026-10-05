import CoreGraphics

/// Window layout metrics (SPEC §5.1).
enum DSMetrics {
    /// Approximate height of the unified toolbar (managed by the system).
    static let toolbarHeight: CGFloat = 56
    /// File name + "N pages" block in the toolbar: at most this wide, so
    /// there is always room for the search field at 1040 pt (SPEC
    /// §5.1 point 8).
    static let toolbarTitleMaxWidth: CGFloat = 200

    /// Default sidebar width, also used as the reset value for a double
    /// click on the divider.
    static let sidebarWidth: CGFloat = 264
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 360
    static let pageZoomBarHeight: CGFloat = 34

    static let rightPanelDefaultWidth: CGFloat = 392
    static let rightPanelMinWidth: CGFloat = 320
    /// Explicit request from the user: "I want to be able to reach half and
    /// half between the PDF and the summary". With the old limit of 520 pt the
    /// right panel could never reach half the window at any practical width
    /// (with the sidebar visible at 264 pt and the two 8 pt dividers, a true
    /// 50/50 on a 1400 pt window needs 580 pt; at 1728 pt, the "more space"
    /// width of the 16" MacBook Pro, it needs 724). Raised to 900: not an
    /// arbitrary value for "as much space as possible", but enough for
    /// `WindowLayoutMath.compute` (which already protects the center's 440 pt
    /// minimum, SPEC §5.1, through `availableForRight`) to return a true
    /// half/half at common window widths instead of clipping the right panel
    /// against a static cap that is too low. See `WindowLayoutMathTests.
    /// fiftyFiftySplitReachableAtCommonWindowWidths`. The 440 pt minimum for
    /// the PDF is unchanged (SPEC; that is not the limit to move).
    static let rightPanelMaxWidth: CGFloat = 900
    /// Width of the draggable area of the two dividers (sidebar and right
    /// panel): 8 pt, comfortable for the pointer.
    static let paneDividerWidth: CGFloat = 8
    static let rightPanelBottomMargin: CGFloat = 72

    /// The center (PDF) never goes below this width (SPEC §5.1).
    static let minCenterWidth: CGFloat = 440

    static let minWindowWidth: CGFloat = 1040
    static let minWindowHeight: CGFloat = 680

    static let thumbnailWidth: CGFloat = 120
    static let cornerRadiusCard: CGFloat = 10
    static let cornerRadiusPill: CGFloat = 9

    // MARK: - Sidebar: three tabs in a row, collapsible legend

    /// Fixed height of a contents row ("untruncated row, consistent row
    /// height"): the same for every level T1-T4, independent of the title
    /// length (title on a single line, ellipsis at the end, never mid-word).
    static let indexRowHeight: CGFloat = 26

    /// Width of the detection strip on the left edge of the sidebar that
    /// reveals the legend ("appears when the cursor approaches the left
    /// edge"). Deliberately narrow so it does not overlap the clickable
    /// contents/thumbnail rows.
    static let legendRevealZoneWidth: CGFloat = 16
    static let legendPanelWidth: CGFloat = 228
    static let legendPanelMaxHeight: CGFloat = 210
}
