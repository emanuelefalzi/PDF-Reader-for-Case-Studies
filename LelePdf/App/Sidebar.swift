import SwiftUI

/// Left sidebar (SPEC §5.3). Verbatim feedback from the user after trying
/// the previous version: "I liked the left menu better before, now with
/// this split, one piece on top and one below, I really don't like it, put
/// it back as it was, and leave the color dot next to 'map', so that there
/// are three: pages, contents, map, and next to these three selections
/// the color dot". It goes back to the earlier shape:
/// - **a single segmented control with three entries**, Pages | Contents |
///   Map (`SidebarTab`), no longer the contents always on top above a
///   two-entry segmented control;
/// - next to it, the same "Subject color" dot as before
///   (`ColorThemeSwatchButton`), the only part of the previous design the
///   user did not object to, so it is carried over unchanged into the
///   restored shape;
/// - **collapsible legend** (`LegendOverlayPanel` below, never objected
///   to by the user), an overlay that appears when the cursor approaches
///   the sidebar's left edge (which is also the window's left edge) or
///   with the "Legend" menu entry (⌥⌘G); never above the privacy note,
///   always on top of Pages/Contents/Map but without stealing their
///   clicks when hidden.
struct Sidebar: View {
    @Environment(DocumentModel.self) private var model

    /// Hover state local to the view (not in the model: it is a
    /// presentation detail, not a preference, unlike `sidebarTab`).
    /// `model.legendForcedVisible` (shortcut/menu) is a separate OR, handled
    /// in `legendVisible`.
    @State private var legendHoverVisible = false
    @State private var legendHideTask: Task<Void, Never>?
    /// Bug reported by the user: "the color menu that appears from the left,
    /// if I select the color it glitches: the pop-up menu disappears, but the
    /// floating color selection stays open". The hue picker INSIDE the
    /// collapsible legend itself opens a popover (see `LegendOverlayPanel`).
    /// A popover is a separate window from `onContinuousHover`'s point of
    /// view: while it is open the cursor is no longer "over" the view tracked
    /// by the legend, so the legend's auto-hide (180 ms after the hover ends)
    /// fired BEFORE the color choice was made, leaving the panel behind gone
    /// and the color popover still hanging in mid-air, detached from
    /// everything. `legendVisible` also takes this state into account: while
    /// the inner popover is open the legend stays visible regardless of hover,
    /// and the two close together when the choice is made (see
    /// `LegendOverlayPanel`, which resets `colorPickerOpen` to `false` as
    /// soon as `colorTheme` changes).
    @State private var colorPickerOpen = false

    var body: some View {
        @Bindable var model = model

        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("Sidebar section", selection: $model.sidebarTab) {
                        ForEach(SidebarTab.allCases, id: \.self) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    ColorThemeSwatchButton()
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))

                Group {
                    switch model.sidebarTab {
                    case .pagine:
                        ThumbnailsSidebar()
                    case .indice:
                        ChaptersSidebar()
                    case .mappa:
                        MapSidebarView()
                    }
                }
                .frame(maxHeight: .infinity)

                PrivacyFootnote()
            }

            LegendOverlayPanel(hue: model.colorTheme, colorTheme: colorThemeBinding, colorPickerOpen: $colorPickerOpen)
                .frame(width: DSMetrics.legendPanelWidth)
                .padding(.leading, 6)
                .padding(.top, 6)
                .opacity(legendVisible ? 1 : 0)
                .offset(x: legendVisible ? 0 : -DSMetrics.legendPanelWidth - 12)
                .allowsHitTesting(legendVisible)
                .animation(.easeInOut(duration: 0.16), value: legendVisible)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    handlePanelHover(phase)
                }
        }
        .background(DSColor.sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DSColor.borderSoft).frame(width: 0.5)
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            handleEdgeHover(phase)
        }
    }

    /// "The color menu must also work with the contents closed": both the
    /// dot in the header and the legend's reveal strip live in this `ZStack`,
    /// outside the `switch` that chooses the active tab, so they work the same
    /// whichever tab is selected (Pages, Contents or Map), "contents closed"
    /// included (that is, with one of the other two tabs selected: there is
    /// no longer a separate contents panel to open/close).
    private var legendVisible: Bool { legendHoverVisible || model.legendForcedVisible || colorPickerOpen }

    private var colorThemeBinding: Binding<MaterialHue> {
        Binding(get: { model.colorTheme }, set: { model.setColorTheme($0) })
    }

    /// Thin strip on the left edge ("appears when the cursor approaches the
    /// left edge"): the only trigger that MAKES the legend APPEAR. Attached to
    /// the whole sidebar (not just the strip) because `onContinuousHover`
    /// never blocks the clicks of the views underneath: no separate view is
    /// needed above the buttons to intercept the hover, so there is no risk
    /// of "stealing" a click as originally feared.
    private func handleEdgeHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            if location.x <= DSMetrics.legendRevealZoneWidth {
                revealLegend()
            } else if legendHoverVisible {
                scheduleLegendHide()
            }
        case .ended:
            scheduleLegendHide()
        }
    }

    /// Once visible, it stays open while the cursor is over the panel itself
    /// (which can be wider than the trigger strip, e.g. to reach the
    /// "Subject color" picker); coordinates are local to the panel itself, so
    /// there is no need to know its position in the sidebar. It ignores the
    /// end of the hover while the color popover is open: otherwise the very
    /// opening of the popover, which moves the cursor out of the tracked
    /// area, would start the auto-hide of the legend beneath it.
    private func handlePanelHover(_ phase: HoverPhase) {
        switch phase {
        case .active:
            guard legendVisible else { return }
            legendHideTask?.cancel()
        case .ended:
            guard !colorPickerOpen else { return }
            scheduleLegendHide()
        }
    }

    private func revealLegend() {
        legendHideTask?.cancel()
        if !legendHoverVisible { legendHoverVisible = true }
    }

    private func scheduleLegendHide() {
        legendHideTask?.cancel()
        legendHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            legendHoverVisible = false
        }
    }
}

/// Privacy note at the bottom of the sidebar (SPEC §5.1 point 6), always
/// visible and independent of the legend: it used to live in the same
/// footer, but has nothing to do with colors/marks; separated so it stays
/// present even with the legend hidden, as before.
private struct PrivacyFootnote: View {
    var body: some View {
        Text("Text sent to Claude · results saved locally")
            .font(.system(size: 11))
            .foregroundStyle(DSColor.textSecondary)
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(DSColor.borderCard).frame(height: 0.5)
            }
    }
}

/// Clickable dot with the subject's current tone, in the sidebar header
/// (unchanged from the previous design): the "Subject color" picker also
/// remains in the collapsible legend, but that is hidden most of the
/// time; this button makes it always reachable, with a single click,
/// without having to bring the cursor to the edge. A popover instead of a
/// `Menu` for the same readability reason as the original `Picker` (label
/// + colored dot per entry), and for the same reason `LegendOverlayPanel`
/// no longer uses a native `Picker`: a pop-up `Picker` on macOS draws its
/// entries as `NSMenuItem`, which re-tint any `Image(systemName:)` with
/// the control's accent color (hence the "all blue" dots), while a
/// SwiftUI popover draws its `ColorThemePickerList` as normal views, each
/// with the true color of its own hue.
private struct ColorThemeSwatchButton: View {
    @Environment(DocumentModel.self) private var model
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Circle()
                .fill(DSColor.markColor(hue: model.colorTheme, tone: .t4))
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(DSColor.borderStrong, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Subject color · \(model.colorTheme.label)")
        .accessibilityLabel("Subject color")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ColorThemePickerList(
                selection: Binding(get: { model.colorTheme }, set: { model.setColorTheme($0) }),
                dismiss: { showPopover = false }
            )
            .padding(10)
        }
    }
}

/// Content of the popover/legend: list of hues with a colored dot, shared
/// between `ColorThemeSwatchButton` and `LegendOverlayPanel` so the two
/// places of the picker always show exactly the same entries. Real
/// SwiftUI views (`Circle`), not entries of a native `Picker`/`Menu`:
/// macOS re-tints `Image(systemName:)` icons inside an `NSMenuItem` with
/// the control's accent color (blue by default), ignoring any
/// `.foregroundStyle` applied in SwiftUI, hence "the colors are all
/// shades of blue, even if it says red", even though the choice itself
/// worked correctly (the `Binding` never goes through the menu, only
/// through `selection`). A `Circle().fill(...)` here is never a menu icon:
/// no re-tinting, each dot shows the true hue.
struct ColorThemePickerList: View {
    @Binding var selection: MaterialHue
    /// Called after setting `selection`: lets the caller close its own
    /// popover right after the choice, instead of leaving it open until the
    /// user clicks elsewhere. `nil` by default so behavior does not change
    /// where it is not needed.
    var dismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(MaterialHue.allCases) { hue in
                Button {
                    selection = hue
                    dismiss?()
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(DSColor.markColor(hue: hue, tone: .t4))
                            .frame(width: 12, height: 12)
                        Text(hue.label)
                            .font(.system(size: 12))
                            .foregroundStyle(DSColor.textPrimary)
                        Spacer()
                        if hue == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DSColor.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
