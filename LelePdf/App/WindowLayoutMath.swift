import CoreGraphics

/// Pure math of the 3-column layout (SPEC §5.1): "the PDF in the center
/// never goes below 440 pt; if there is not enough space, first the right
/// panel shrinks down to 320 pt, then the sidebar closes
/// automatically".
///
/// Design decision: the returned widths are derived on every layout pass
/// from the total available width, never writing
/// `sidebarVisible`/`rightPanelWidth` into the model. This way the
/// auto-shrinking is always reversible (widening the window again brings
/// the panels back to their preferred size) and the sidebar button in the
/// toolbar keeps reflecting the user's preference, not the temporary
/// state imposed by the available space.
///
/// The sidebar also has a preferred width (draggable, 200-360 pt) instead
/// of the fixed constant `DSMetrics.sidebarWidth`; the shrinking cascade
/// stays the one in SPEC (first the right panel down to 320 pt, then the
/// sidebar closes entirely, never a middle way such as a "narrowed
/// sidebar").
enum WindowLayoutMath {
    struct Result: Equatable {
        let sidebarWidth: CGFloat
        let rightPanelWidth: CGFloat
    }

    static func compute(
        totalWidth: CGFloat,
        sidebarVisible: Bool,
        rightPanelVisible: Bool,
        preferredSidebarWidth: CGFloat = DSMetrics.sidebarWidth,
        preferredRightPanelWidth: CGFloat
    ) -> Result {
        let minCenter = DSMetrics.minCenterWidth
        var sidebar: CGFloat = sidebarVisible
            ? min(max(preferredSidebarWidth, DSMetrics.sidebarMinWidth), DSMetrics.sidebarMaxWidth)
            : 0
        var right: CGFloat = rightPanelVisible
            ? min(max(preferredRightPanelWidth, DSMetrics.rightPanelMinWidth), DSMetrics.rightPanelMaxWidth)
            : 0

        if rightPanelVisible {
            let dividerWidth = (sidebar > 0 ? DSMetrics.paneDividerWidth : 0) + DSMetrics.paneDividerWidth
            let availableForRight = totalWidth - sidebar - dividerWidth - minCenter
            if right > availableForRight {
                right = max(DSMetrics.rightPanelMinWidth, availableForRight)
            }
        }

        let dividerWidth = (sidebar > 0 ? DSMetrics.paneDividerWidth : 0)
            + (right > 0 ? DSMetrics.paneDividerWidth : 0)
        let center = totalWidth - sidebar - right - dividerWidth
        if center < minCenter, sidebarVisible {
            sidebar = 0
        }

        return Result(sidebarWidth: max(0, sidebar), rightPanelWidth: max(0, right))
    }
}
