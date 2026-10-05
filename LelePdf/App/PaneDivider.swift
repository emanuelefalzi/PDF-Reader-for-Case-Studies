import SwiftUI
import AppKit

/// Pure math of dragging a divider (separate from `PaneDivider` so a test
/// can verify it without mounting SwiftUI, same principle as
/// `ChatButtonLayout`/`ChatOverlay`).
enum PaneDividerMath {
    static func resize(
        base: CGFloat,
        translation: CGFloat,
        growsWithPositiveTranslation: Bool,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        let signed = growsWithPositiveTranslation ? translation : -translation
        return min(max(base + signed, range.lowerBound), range.upperBound)
    }
}

/// Generic draggable divider between two columns of the 3-pane layout
/// (SPEC §5.1): used both between sidebar and center and between center
/// and right panel. Before, only the right panel had a divider; the
/// sidebar was fixed at 264 pt with no way to resize it, which was
/// exactly the "I can't adjust the size of the two panes" reported by
/// the user.
struct PaneDivider: View {
    /// Width of the adjacent panel, updated by the drag.
    let width: Binding<CGFloat>
    let range: ClosedRange<CGFloat>
    /// Restored with a double click on the divider.
    let defaultWidth: CGFloat
    /// `true` for the sidebar (dragging right widens), `false` for the right
    /// panel (dragging right narrows).
    let growsWithPositiveTranslation: Bool
    /// Called with `true` on the first drag event and with `false` on release,
    /// so the caller can treat the drag as a resize transition
    /// (`WindowResizeCoalescer.begin()/end()`, the same mechanism as Full
    /// Screen): right panel width frozen and the PDF's `autoScales`
    /// suspended for the duration of the gesture, a single real layout pass
    /// on release. Measured: 123 ms per mouse event without it (8 frames per
    /// second, the divider "lagging"), because every event redid the SwiftUI
    /// layout of all the cards.
    var onDragging: ((Bool) -> Void)? = nil

    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: DSMetrics.paneDividerWidth)
            .overlay(Rectangle().fill(DSColor.borderSoft).frame(width: 0.5))
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            // `minimumDistance: 1` instead of 0 (SPEC): a still click does not
            // trigger `onChanged`, so the double click below for resetting stays
            // recognizable; with 0 the drag always "wins" and the tap never
            // arrives.
            .simultaneousGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = startWidth ?? width.wrappedValue
                        if startWidth == nil {
                            startWidth = base
                            onDragging?(true)
                        }
                        let proposed = PaneDividerMath.resize(
                            base: base,
                            translation: value.translation.width,
                            growsWithPositiveTranslation: growsWithPositiveTranslation,
                            range: range
                        )
                        setWidth(proposed, animated: false)
                    }
                    .onEnded { _ in
                        startWidth = nil
                        onDragging?(false)
                    }
            )
            // Safety net: if the view disappears mid-gesture (panel closed from the
            // keyboard during the drag) the transition is closed anyway; `end()` is
            // idempotent.
            .onDisappear {
                if startWidth != nil {
                    startWidth = nil
                    onDragging?(false)
                }
            }
            .onTapGesture(count: 2) {
                setWidth(defaultWidth, animated: true)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Resize panel")
    }

    /// During the drag the width updates WITHOUT the animation of
    /// `ThreePaneLayout` (`.animation(value: layout)`), which would otherwise
    /// smooth every micro-change over 180 ms and make the panel look "late"
    /// behind the mouse; with many events per second the delay accumulates
    /// and the drag seems stuck. The `Transaction` with `disablesAnimations`
    /// always wins over an ancestor's `.animation` modifier for this specific
    /// update, without having to disable the animation everywhere (it stays
    /// useful for opening/closing the sidebar and panel, and for the
    /// double-click reset, where it should be smooth).
    private func setWidth(_ proposed: CGFloat, animated: Bool) {
        let clamped = min(max(proposed, range.lowerBound), range.upperBound)
        var transaction = Transaction()
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            width.wrappedValue = clamped
        }
    }
}
