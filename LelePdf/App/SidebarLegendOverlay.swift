import SwiftUI

/// Collapsible legend (verbatim feedback from the user: "a whole legend at
/// the bottom left makes no sense, one could almost think of a section that
/// appears only if I move the cursor all the way to the left"). It used to
/// be `LegendFooter`, a fixed box at the bottom of the sidebar that was
/// always present (SPEC §5.1 point 5, §5.4); it is now a floating panel
/// drawn ON TOP of the sidebar by `Sidebar` (never instantiated inside a
/// normal `VStack` there), which that view shows/hides with opacity +
/// `allowsHitTesting` based on hover over the left edge or on the "Legend"
/// shortcut (⌥⌘G).
///
/// Content unchanged from `LegendFooter`: the 4 marks (SPEC §5.4) and the
/// "Subject color" picker (SPEC §5.4 v2.6 "a picker ... in the sidebar
/// legend"), which is kept here as well as in the header
/// (`ColorThemeSwatchButton`), so whoever already knows where to look finds
/// it in the same place as before.
///
/// Bugs reported verbatim by the user: the picker is NO LONGER a native
/// `Picker`. Two problems from the same widget:
/// - **First problem**: a pop-up `Picker` opens its entries as an `NSMenu`,
///   a window separate from the one tracked by `onContinuousHover` in
///   `Sidebar`. As soon as it opens, the cursor "leaves" the observed
///   area and the legend's auto-hide (180 ms) starts, so the legend
///   disappeared BEFORE the choice was completed: the panel behind hid,
///   but the `Picker`'s menu stayed hanging in mid-air, detached from
///   everything ("the pop-up menu disappears, but the floating color
///   selection stays open").
/// - **Second problem**: the same entries used `Label(hue.label,
///   systemImage: "circle.fill").foregroundStyle(...)` for the dot, but
///   macOS draws the entries of a `Picker`/`Menu` as `NSMenuItem`, which
///   RE-TINT any `Image(systemName:)` with the control's accent color
///   (blue by default), ignoring the SwiftUI `.foregroundStyle`. Result:
///   "the colors are all shades of blue, even if it says red", although
///   the actual choice stayed correct (the `Binding` reads/writes
///   `selection`, never a color drawn by the menu), hence "when you click
///   it works and changes all the colors".
///
/// A button with a dot (a real SwiftUI view, never a menu icon) that
/// opens a popover with `ColorThemePickerList` solves both: no `NSMenu`
/// (so no race with the auto-hide; `colorPickerOpen` still keeps the
/// legend visible while the popover is open, see `Sidebar.legendVisible`)
/// and no re-tinting (the dots in `ColorThemePickerList` are
/// `Circle().fill(...)`, not menu icons).
struct LegendOverlayPanel: View {
    let hue: MaterialHue
    @Binding var colorTheme: MaterialHue
    @Binding var colorPickerOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("LEGEND")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DSColor.labelUppercase)
                .tracking(0.3)

            let items: [(String, Color)] = [
                ("Concept", DSColor.markColors(for: .rectangle, hue: hue).stroke),
                ("Who / how much", DSColor.markColors(for: .circle, hue: hue).stroke),
                ("Action", DSColor.markColors(for: .underline, hue: hue).stroke),
                ("Consequence", DSColor.markColors(for: .arrow, hue: hue).stroke),
            ]
            FlowLegend(items: items)

            HStack(spacing: 6) {
                Text("Subject color")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
                Spacer()
                Button {
                    colorPickerOpen = true
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(DSColor.markColor(hue: colorTheme, tone: .t4))
                            .frame(width: 11, height: 11)
                        Text(colorTheme.label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DSColor.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(DSColor.textTertiary)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .frame(width: 122)
                    .background(DSColor.pillBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(DSColor.borderSoft, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $colorPickerOpen, arrowEdge: .bottom) {
                    ColorThemePickerList(selection: $colorTheme, dismiss: { colorPickerOpen = false })
                        .padding(10)
                }
            }
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        .frame(maxHeight: DSMetrics.legendPanelMaxHeight, alignment: .top)
        .background(DSColor.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard))
        .overlay(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard).stroke(DSColor.borderStrong, lineWidth: 0.7))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

private struct FlowLegend: View {
    let items: [(String, Color)]

    var body: some View {
        // Two simple columns: enough for 4 entries and it does not require one
        // more custom Layout (M1, unchanged from `LegendFooter`).
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(items[index].1)
                        .frame(width: 9, height: 9)
                    Text(items[index].0)
                        .font(.system(size: 11))
                        .foregroundStyle(DSColor.textPrimary.opacity(0.85))
                }
            }
        }
    }
}
