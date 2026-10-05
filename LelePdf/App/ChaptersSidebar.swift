import AppKit
import SwiftUI

/// "Contents" tab: the contents tree, built-in or generated (SPEC §5.3,
/// §7.4). Verbatim feedback from the user after trying the previous
/// version: "I liked the left menu better before, now with this split, one
/// piece on top and one below, I really don't like it, put it back as it
/// was". It is a tab of the `Pages | Contents | Map` segmented control
/// (`App/Sidebar.swift`) again, as before the split, no longer a panel
/// always on top of the sidebar with a dedicated show/hide button (the tab
/// selection itself acts as show/hide, and the chosen tab is what is
/// remembered, `SidebarPreferences.sidebarTab`).
///
/// The content of the tree (`ChapterRow`) stays as introduced earlier and
/// was NEVER questioned by the user's feedback: readable T1-T4 hierarchy
/// (decreasing weight/size), single row with a tail ellipsis, fixed row
/// height, highlighting of the current row with the subject color instead
/// of a fixed blue.
///
/// Every entry with children can be collapsed/expanded (`ChapterRow` gains
/// a disclosure triangle, this file filters the hidden rows and handles
/// selection/arrows; see `DocumentModelTocCollapse.swift`/
/// `TextPipeline/TocCollapse.swift` for the logic).
struct ChaptersSidebar: View {
    // Not `private`: `granularityRow` lives in
    // `ChaptersSidebarGranularity.swift`, same type, separate file to keep
    // files short; the same principle already in use elsewhere in the app.
    @Environment(DocumentModel.self) var model
    @State private var renamingEntry: TocEntry?
    @State private var renameText = ""
    /// "Selected" entry for the left/right arrows (a concept distinct from
    /// the "current" entry highlighted by the reading position): a click on
    /// the title or the triangle sets it.
    @State private var selectedEntryID: String?
    @FocusState private var isTocFocused: Bool

    var body: some View {
        let _ = PerfProbe.hit("swiftui.ChaptersSidebar.body")
        VStack(spacing: 0) {
            header
            granularityRow
            content
        }
        .alert("Rename entry", isPresented: Binding(get: { renamingEntry != nil }, set: { if !$0 { renamingEntry = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renamingEntry = nil }
            Button("Rename") {
                if let entry = renamingEntry { model.renameTocEntry(id: entry.id, title: renameText) }
                renamingEntry = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DSColor.textTertiary)
            // "Regenerate Contents" on top of an already present contents gave no
            // sign of life (the large spinner appears only when the list is empty): a
            // small spinner next to the title while the call is in progress.
            if model.tocGenerationState == .generating, !model.tocEntries.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Regenerating contents")
            }
            Spacer()
            Menu {
                Button("Regenerate contents") { model.regenerateToc() }
                    .disabled(model.tocGenerationState == .generating || model.structure?.tocCandidates.isEmpty != false)
                Divider()
                // "Show Only T1"/"Expand All": the same commands are also in the
                // Contents menu (`App/ContentsCommands.swift`), here for those who do not
                // remember the shortcut/the system menu.
                Button("Show Only T1") { model.showOnlyTopLevelTocEntries() }
                    .disabled(!hasAnyCollapsibleEntry)
                Button("Expand All") { model.expandAllTocEntries() }
                    .disabled(model.collapsedTocEntryIds.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DSColor.borderSoft).frame(height: 0.5)
        }
    }

    private var headerTitle: String {
        switch model.tocSource {
        case .generated: String(localized: "Generated contents")
        case .native: String(localized: "PDF contents")
        case .none: String(localized: "Contents")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.tocGenerationState {
        case .generating where model.tocEntries.isEmpty:
            generatingState
        case .failed(let message) where model.tocEntries.isEmpty:
            errorState(message)
        default:
            if model.tocEntries.isEmpty {
                emptyState
            } else {
                // The list is a CHILD view because it reads `currentTocEntry` (which
                // changes on every scroll tick): inside this `body` the read redid the
                // whole tab (header with `Menu` and the "Summarise by" row with `Menu`,
                // i.e. two real `NSPopUpButton`/`NSMenu`) on every tick (benchmark: ~5 ms
                // per tick with the Contents tab compared to Pages, on base and HEAD).
                ChaptersIndexList(selectedEntryID: $selectedEntryID, isTocFocused: $isTocFocused) { entry in
                    renameText = entry.title
                    renamingEntry = entry
                }
            }
        }
    }

    private var generatingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Generating the table of contents…")
                .font(.system(size: 11.5))
                .foregroundStyle(DSColor.textSecondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(DSColor.textTertiary)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(DSColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { model.regenerateToc() }
                .font(.system(size: 11.5, weight: .medium))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 22))
                .foregroundStyle(DSColor.textTertiary)
            Text("Contents not available")
                .font(.system(size: 12, weight: .medium))
            Text(Self.emptyStateHint(structure: model.structure))
                .font(.system(size: 11))
                .foregroundStyle(DSColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "will be generated" was a false promise when the pipeline has already
    /// finished without finding a single candidate heading (no generation
    /// will ever start, SPEC §7.4, and "Regenerate Contents" is rightly
    /// disabled): only the manual contents remains (SPEC §5.3 "even without a
    /// contents"), and the text says so. Static and pure: SwiftUI's text is
    /// not readable from the AppKit hierarchy in tests, so the message choice
    /// is verified here.
    static func emptyStateHint(structure: DocumentStructure?) -> String {
        structure?.tocCandidates.isEmpty == true
            ? String(localized: "No headings found; select a title and use T1–T4")
            : String(localized: "will be generated")
    }

    /// Menu "Show Only T1" of the header: is there at least one entry with
    /// children? Same pure basis as `ChaptersIndexList` (`TocCollapse`).
    private var hasAnyCollapsibleEntry: Bool {
        TocCollapse.hasChildren(depths: ManualToc.indentDepths(levels: model.tocEntries.map(\.level))).contains(true)
    }
}

/// The contents list, a view of its own: it is the only part of the
/// Contents tab that depends on the reading position (`currentTocEntry`,
/// one read per scroll tick), so it is the only one re-evaluated on every
/// tick; the header and the "Summarise by" row (two `Menu`s, i.e. real
/// `NSMenu`s) stay still. The selection and the focus stay
/// `@State`/`@FocusState` of `ChaptersSidebar` (the context menu uses
/// them too) and arrive here as bindings.
private struct ChaptersIndexList: View {
    @Environment(DocumentModel.self) private var model
    @Binding var selectedEntryID: String?
    var isTocFocused: FocusState<Bool>.Binding
    /// "Rename..." from the context menu: opens `ChaptersSidebar`'s alert.
    let onRename: (TocEntry) -> Void

    /// Depth (visual indentation) and visibility of each entry, recomputed
    /// from the same `model.tocEntries` array on every change: pure,
    /// `TocCollapse`/`ManualToc`, no state duplicated here.
    private var depths: [Int] { ManualToc.indentDepths(levels: model.tocEntries.map(\.level)) }
    private var hasChildrenFlags: [Bool] { TocCollapse.hasChildren(depths: depths) }
    private var visibleFlags: [Bool] {
        TocCollapse.visibleIndices(ids: model.tocEntries.map(\.id), depths: depths, collapsed: model.collapsedTocEntryIds)
    }
    private var hasAnyCollapsibleEntry: Bool { hasChildrenFlags.contains(true) }

    var body: some View {
        PerfProbe.hit("swiftui.IndexPanel.list")
        let currentEntry = model.currentTocEntry
        let depths = depths
        let hasChildrenFlags = hasChildrenFlags
        let visibleFlags = visibleFlags
        // `collapsedTocEntryIds` is a computed property that builds a `Set` from
        // the record's array on EVERY read; read inside the `ForEach` it cost a
        // new `Set` per row, i.e. O(entries^2) on every re-evaluation of the
        // list (one per scroll tick, via `currentTocEntry`). A single read.
        let collapsed = model.collapsedTocEntryIds

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.tocEntries.enumerated()), id: \.element.id) { index, entry in
                    if visibleFlags[index] {
                        ChapterRow(
                            entry: entry, isCurrent: entry.id == currentEntry?.id, depth: depths[index],
                            hasChildren: hasChildrenFlags[index], isCollapsed: collapsed.contains(entry.id),
                            isSelected: entry.id == selectedEntryID,
                            onNavigate: { selectedEntryID = entry.id; isTocFocused.wrappedValue = true; model.goToTocEntry(entry) },
                            onToggle: { selectedEntryID = entry.id; isTocFocused.wrappedValue = true; model.toggleTocEntryCollapsed(id: entry.id) },
                            onToggleSubtree: { selectedEntryID = entry.id; isTocFocused.wrappedValue = true; model.toggleTocSubtreeCollapsed(id: entry.id) }
                        )
                        // This list is re-evaluated on every scroll tick; SwiftUI cannot compare
                        // a row that carries closures and redid ALL the mounted rows per tick
                        // (probe `swiftui.ChapterRow.body`: 4 rows x 3 ticks = 12 in the test, 65
                        // per tick on the Merck). With `Equatable` on the values it redoes only
                        // those whose values change.
                        .equatable()
                        .contextMenu { contextMenu(for: entry) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .focusable()
        .focused(isTocFocused)
        // "Left/right arrows collapse/expand the selected entry, as in the
        // Finder": the logic of what happens (collapse / go up to the parent /
        // expand / go down to the first child) lives in `DocumentModel`
        // (`collapseSelectedTocEntry`/`expandSelectedTocEntry`, pure on top of
        // `TocCollapse`), here only the hookup with the real keyboard and the
        // selection update.
        .onKeyPress(.leftArrow) {
            guard let selectedEntryID else { return .ignored }
            self.selectedEntryID = model.collapseSelectedTocEntry(id: selectedEntryID)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard let selectedEntryID else { return .ignored }
            self.selectedEntryID = model.expandSelectedTocEntry(id: selectedEntryID)
            return .handled
        }
    }

    /// v2.3 §5.3: "Change level" (T1-T4), "Rename", "Remove" on any entry
    /// (built-in/generated/manual; removing an automatic one turns it into a
    /// manual tombstone). "Regenerate Contents" is available in the header
    /// even above a built-in or empty contents.
    @ViewBuilder
    private func contextMenu(for entry: TocEntry) -> some View {
        Menu("Change level") {
            ForEach(1 ... 4, id: \.self) { level in
                Button("T\(level)") { model.changeTocEntryLevel(id: entry.id, level: level) }.disabled(level == entry.level)
            }
        }
        Button("Rename…") { onRename(entry) }
        Button("Remove") { model.removeTocEntry(id: entry.id) }
        Divider()
        Button("Regenerate contents") { model.regenerateToc() }
            .disabled(model.tocGenerationState == .generating || model.structure?.tocCandidates.isEmpty != false)
        Divider()
        Button("Show Only T1") { model.showOnlyTopLevelTocEntries() }
            .disabled(!hasAnyCollapsibleEntry)
        Button("Expand All") { model.expandAllTocEntries() }
            .disabled(model.collapsedTocEntryIds.isEmpty)
    }
}

/// Contents row ("clear T1-T4 hierarchy with indentation, current title
/// highlighted, rows not truncated mid-word, consistent row height"):
/// the earlier work only touched the CONTAINER (it is a tab again instead
/// of a panel always on top), not this content, which the user never
/// objected to:
/// - **increasing indentation** per level (`depth` from `ManualToc.indentDepths`);
/// - **different weight/size/color for T1-T4** (not just T1 vs the rest
///   as in the earliest form), so the hierarchy reads even without
///   counting the indentation;
/// - **a single row with an ellipsis at the end** (`lineLimit(1)`, never
///   `.middle`/mid-word) instead of `lineLimit(2)`: a long title wrapping
///   onto two lines for THAT entry only makes row heights inconsistent;
///   the tail ellipsis keeps every row at the same height
///   (`DSMetrics.indexRowHeight`) at any width between 200 and 360 pt;
/// - **highlighting with the subject color**, not a fixed blue
///   (`DSColor.accent`/`accentBackground`): a color consistency bug (quality
///   criterion "a single subject color ... used everywhere ... contents"),
///   since the contents was the only place left on the app's fixed accent
///   instead of the document's hue.
///
/// It gains the expand/collapse triangle (`DisclosureTriangle`, visible on
/// mouse hover; a design choice left open is that it is also shown in
/// light gray on COLLAPSED entries even without hover, so it is immediately
/// visible where there is more below without having to hover every row)
/// and a light background for the SELECTED entry (distinct from the
/// CURRENT entry, which uses the subject color).
private struct ChapterRow: View, Equatable {
    let entry: TocEntry
    let isCurrent: Bool
    let depth: Int
    let hasChildren: Bool
    let isCollapsed: Bool
    let isSelected: Bool
    let onNavigate: () -> Void
    let onToggle: () -> Void
    let onToggleSubtree: () -> Void

    @Environment(DocumentModel.self) private var model
    @State private var isHovered = false

    private var level: Int { max(1, min(4, entry.level)) }

    private var titleFont: Font {
        switch level {
        case 1: .system(size: 12.5, weight: .semibold)
        case 2: .system(size: 12, weight: .medium)
        case 3: .system(size: 11.5, weight: .regular)
        default: .system(size: 11, weight: .regular)
        }
    }

    private var titleColor: Color {
        guard !isCurrent else { return highlightColors.stroke }
        return switch level {
        case 1: DSColor.textPrimary
        case 2: DSColor.textPrimary.opacity(0.9)
        default: DSColor.textSecondary
        }
    }

    /// Same tone assignment as the "rectangle" mark (SPEC §5.4 v2.6 "light
    /// background with medium border"): reused here instead of inventing a
    /// third one, to stay consistent with `BlockCardView.accentBarColor`,
    /// which marks the current section in the right panel the same way.
    private var highlightColors: DSColor.MarkColors {
        DSColor.markColors(for: .rectangle, hue: model.colorTheme)
    }

    var body: some View {
        let _ = PerfProbe.hit("swiftui.ChapterRow.body")
        HStack(spacing: 2) {
            triangle
            Button(action: onNavigate) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(titleFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(titleColor)
                    if entry.isManual {
                        Image(systemName: "hand.point.up.left")
                            .font(.system(size: 8.5))
                            .foregroundStyle(DSColor.textTertiary)
                            .help("Manual entry")
                    }
                    Spacer(minLength: 8)
                    Text("\(entry.page + 1)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DSColor.textTertiary)
                        .fixedSize()
                }
                .frame(height: DSMetrics.indexRowHeight)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14 + CGFloat(depth) * 12)
        .background(isCurrent ? highlightColors.fill.opacity(0.75) : (isSelected ? DSColor.borderSoft.opacity(0.5) : Color.clear))
        .onHover { isHovered = $0 }
    }

    /// Equality on the VALUES only (the `onNavigate`/`onToggle`/
    /// `onToggleSubtree` closures are recreated on every list body but capture
    /// the same `entry`: they do not tell two rows apart). The hover state is
    /// the row's `@State` and does not enter the comparison;
    /// `model.colorTheme` is read in the body and stays observed separately.
    /// `nonisolated` like `BlockCardView.==`: `Equatable.==` is a
    /// non-isolated requirement, the compared fields are `Sendable` values.
    nonisolated static func == (lhs: ChapterRow, rhs: ChapterRow) -> Bool {
        lhs.entry == rhs.entry && lhs.isCurrent == rhs.isCurrent && lhs.depth == rhs.depth
            && lhs.hasChildren == rhs.hasChildren && lhs.isCollapsed == rhs.isCollapsed && lhs.isSelected == rhs.isSelected
    }

    /// Only on mouse hover ("appears only when I hover over it"); a design
    /// choice left open is that it stays visible even without hover, in light
    /// gray, on ALREADY COLLAPSED entries, so the user immediately sees which
    /// titles hide more without having to hover each one; an expanded entry
    /// without hover shows nothing (no clutter). No space is reserved for
    /// entries without children (`hasChildren == false`).
    @ViewBuilder
    private var triangle: some View {
        if hasChildren {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(isHovered ? DSColor.textSecondary : (isCollapsed ? DSColor.textTertiary.opacity(0.6) : .clear))
                .frame(width: 12, height: DSMetrics.indexRowHeight, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture(count: 1) {
                    // ⌥-click ("expands/collapses the whole subtree"):
                    // `NSEvent.modifierFlags` read at click time; SwiftUI does not pass the
                    // modifiers to `onTapGesture`, but AppKit does through the app's
                    // current event.
                    if NSEvent.modifierFlags.contains(.option) { onToggleSubtree() } else { onToggle() }
                }
        } else {
            Color.clear.frame(width: 12, height: DSMetrics.indexRowHeight)
        }
    }
}
