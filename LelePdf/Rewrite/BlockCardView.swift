import SwiftUI

/// The instruction behind a "…" menu entry (SPEC §5.6): the first two have a
/// fixed text (`CardInstructions`, Resources), the third a free-form
/// instruction from the popover's text field.
enum CardRegenerationKind: Equatable {
    case shorter, moreDetailed, custom(String)

    var instructionText: String {
        switch self {
        case .shorter: CardInstructions.load().shorter
        case .moreDetailed: CardInstructions.load().moreDetailed
        case .custom(let text): text
        }
    }
}

/// Which line of THIS card is being edited in place right now, plus where to
/// put the caret (offset of the triple-click, or start of text when opened
/// from the menu). One field per card: one line at a time.
struct RewriteLineEditingTarget: Equatable {
    var ref: RewriteEditText.LineRef
    var caret: Int
}

/// Card for an analyzed block (SPEC §5.6): title plus page chip, then the
/// rewrite items in the order received (`summary` always first, by
/// construction of `AnalysisPostProcessor`/SPEC §7.5).
/// "…" menu and text editing: SPEC §5.6 "Shorter"/"More Detailed"/"Rewrite
/// Like This…"/"Edit Text"/"Restore Claude's Version", with mandatory
/// confirmation before overwriting an edited card ("Protection of manual
/// edits"). Editing replaces the earlier whole-card blob editor with in-place
/// editing of ONE line at a time: triple-click on a line makes that line
/// editable with its real typography, ⌘↩ saves, Esc cancels, a click outside
/// saves.
struct BlockCardView: View, Equatable {
    let blockId: String
    /// Passed in by the caller (`RewritePanel.rowView`) instead of being read
    /// from `model` inside `body`, so this view can declare itself
    /// `Equatable` on concrete values and `RewritePanel` marks it
    /// `.equatable()`. SwiftUI then skips `body` (and the costly relayout of
    /// `MarkedNSTextView`/`NSTextView` below) for cards whose block did NOT
    /// change, instead of redoing ALL visible cards for every single mark
    /// added/changed/removed in any block. Before, `body` read
    /// `model.analysisController.cardData(for:)`, which depends on the whole
    /// `context`, a single `@Observable` property replaced wholesale on every
    /// mutation, so EVERY card considered itself "changed". `isRegenerating`
    /// is part of the comparison for the same reason (SPEC §7.6): without it,
    /// a card being regenerated would not immediately show the "Claude is
    /// regenerating" placeholder if `cardData` had not changed yet in the
    /// meantime.
    let cardData: AnalysisController.BlockCardData
    let isRegenerating: Bool
    /// True if this block is the "focused" one
    /// (`DocumentModel.currentFocusedBlockId`, computed by the caller, same
    /// pattern as `isRegenerating` above, so it stays comparable in `==`
    /// instead of reading `model` inside `body`). It helps tell which card
    /// belongs to which section.
    let isCurrent: Bool
    /// The "3.2" label computed by the caller (`RewriteRowStack.rowView`) and
    /// compared in `==`, like `cardData`/`isRegenerating`. Read from `model`
    /// inside `body`, it went through `context`, the whole `@Observable`
    /// context, replaced on every mark added/removed and every analysis that
    /// arrived, so EVERY built card re-evaluated its body (and reconfigured
    /// all its lines) on every mutation, exactly what the `Equatable`
    /// comparison above had removed. `nil` (tests/previews): read from the
    /// model as before.
    var humanLabel: String? = nil
    @Environment(DocumentModel.self) private var model

    @State private var editingLine: RewriteLineEditingTarget?
    @State private var pendingConfirmation: CardRegenerationKind?
    @State private var showCustomInstructionSheet = false
    @State private var customInstructionText = ""

    // `nonisolated`: the view is implicitly MainActor (SwiftUI, Swift 6 strict
    // concurrency), but `Equatable.==` is a `nonisolated` requirement of the
    // protocol. The compared fields are simple `Sendable` values (`String`,
    // `BlockCardData: Sendable & Equatable`, `Bool`), readable from outside
    // the MainActor without problems.
    nonisolated static func == (lhs: BlockCardView, rhs: BlockCardView) -> Bool {
        lhs.blockId == rhs.blockId && lhs.cardData == rhs.cardData && lhs.isRegenerating == rhs.isRegenerating && lhs.isCurrent == rhs.isCurrent && lhs.humanLabel == rhs.humanLabel
    }

    /// "Edit Text" is enabled if the card has at least one editable line. Same
    /// criterion as `RewriteEditText.firstLineRef` (`items[i].text` for the
    /// single-field types, the first list/step/cell/outline entry for the
    /// others), but read from the card's already-resolved data
    /// (`cardData.rewrite`) and not from `rawRewriteItems(for:)`, which would
    /// re-read `context` inside `body`.
    nonisolated static func hasEditableLine(_ items: [AnalysisController.ResolvedRewriteItem]) -> Bool {
        items.contains { item in
            switch item.kind {
            case .summary, .paragraph, .definition, .callout: return true
            case .bullets, .steps: return !(item.itemSegments ?? []).isEmpty
            case .table: return !(item.rowSegments?.first ?? []).isEmpty
            case .outline: return !(item.lines ?? []).isEmpty
            }
        }
    }

    var body: some View {
        let data = cardData
        let label = humanLabel ?? model.analysisController.humanBlockLabel(for: blockId)
        // `PerfProbe`: counts re-evaluations of this body.
        let _ = PerfProbe.hit("swiftui.BlockCardView.body")
        // The accent of the focused block no longer goes through `isCurrent`
        // read by the caller; `FocusAccentBar` observes it on its own (see
        // `RewriteRowStack.swift`). `isCurrent` stays as a "forced accent"
        // (tests, previews) and in the `Equatable` contract.
        CardContainer(focusAccentBlockId: blockId, focusAccentForced: isCurrent) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    // "3.2 · Title", no longer just the title: the
                    // chapter.block label (`humanBlockLabel`, already computed
                    // for "Continue with the next one" and the regenerating
                    // placeholder below) was invisible on this card until an
                    // error needed it. It helps tell which card belongs to
                    // which section.
                    Text("\(label) · \(data.title)")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DSColor.textPrimary)
                    if data.edited {
                        Text("edited")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(DSColor.textTertiary)
                    }
                }
                Spacer(minLength: 6)
                PageChip(page: data.page, label: RewriteViewModel.pageRangeLabel(start: data.page, end: data.pageEnd)) { model.goToPage(data.page) }
                if editingLine == nil { cardMenu(edited: data.edited, canEditText: Self.hasEditableLine(data.rewrite)) }
            }
            if isRegenerating {
                RegeneratingRow(humanLabel: label) {
                    model.analysisController.cancelRegeneration(blockId: blockId)
                }
            } else {
                ForEach(Array(data.rewrite.enumerated()), id: \.offset) { index, item in
                    // `isEditable: true` was missing: `RewriteItemView.isEditable`
                    // is `false` by default (Summary Lab, previews), so on the
                    // REAL card a triple-click never opened the editor and
                    // "Edit Text" from the menu set `editingLine` without any
                    // editor ever able to reset it to `nil`: ⌘↩/⌘F disabled
                    // and the "…" menu gone while the window stayed open.
                    // `InlineLineEditingTests` only hosted
                    // `RewriteItemView(isEditable: true)`, not this card; the
                    // later suite uses the real panel.
                    RewriteItemView(item: item, itemIndex: index, model: model, blockId: blockId, isEditable: true, editingLine: $editingLine, onCommitLine: commitLineEdit)
                }
            }
        }
        .alert(RewriteViewModel.overwriteConfirmationTitle, isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } })) {
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
            Button("Replace") {
                if let kind = pendingConfirmation { startRegeneration(kind) }
                pendingConfirmation = nil
            }
        } message: {
            Text(RewriteViewModel.overwriteConfirmationMessage)
        }
        .sheet(isPresented: $showCustomInstructionSheet) {
            CustomInstructionSheet(text: $customInstructionText) {
                showCustomInstructionSheet = false
                requestRegeneration(.custom(customInstructionText), edited: data.edited)
            }
        }
        // "Hovering a card highlights the block in the PDF and vice versa":
        // `setHoveredBlock` drives both the accent of this card (`isCurrent`,
        // passed by the caller) and the stronger margin bar in the PDF
        // (`MarksOverlayDrawing.drawMarginBars`), a single source of truth
        // (`DocumentModel.currentFocusedBlockId`).
        .onHover { hovering in model.setHoveredBlock(hovering ? blockId : nil) }
        // A card with a line in "Edit Text" stays built even if it scrolls out
        // of the lazy window (`RewritePanelGeometry.setPinned`), otherwise it
        // would lose the text being edited (`@State` / the not-yet-saved
        // content of the `NSTextView`). Row id as in
        // `RewriteViewModel.rows(from:)`. The block enters/leaves
        // `AnalysisController.editingLineBlockIds` here, in a single place;
        // this disables ⌘↩/⌘F while a line is being edited.
        .onChange(of: editingLine) { _, newValue in
            let editing = newValue != nil
            model.rewritePanelGeometry.setPinned("b-\(blockId)", editing)
            if editing {
                model.analysisController.beginEditingLine(blockId: blockId)
            } else {
                model.analysisController.endEditingLine(blockId: blockId)
            }
        }
        // If the card DISAPPEARS with a line still being edited (right panel
        // hidden with ⌘⇧2, a granularity change or a new segmentation that
        // makes the block an orphan, window closed), the `onChange` above
        // never fires again (the `@State` dies with the view), and
        // `editingLineBlockIds`/`pinned` would stay set forever: ⌘↩ "Analyze
        // the next block" and ⌘F would stay disabled until restart. The text
        // being edited is already saved anyway by the editor's
        // `resignFirstResponder` ("a click outside saves") when AppKit
        // removes it from the window; here we only close the bookkeeping.
        .onDisappear {
            guard editingLine != nil else { return }
            model.rewritePanelGeometry.setPinned("b-\(blockId)", false)
            model.analysisController.endEditingLine(blockId: blockId)
        }
    }

    /// Saves the line through the line-scoped path (`saveManualEditLine`), then
    /// ends editing. Always called from the editor's `onSave` (⌘↩, or a click
    /// outside/on another line), never from `onCancel` (Esc), which just
    /// closes without saving.
    private func commitLineEdit(_ ref: RewriteEditText.LineRef, _ text: String, _ spans: [RewriteEditText.MarkSpan]) {
        Task { await model.analysisController.saveManualEditLine(blockId: blockId, ref: ref, editedText: text, editedSpans: spans) }
        editingLine = nil
    }

    private func requestRegeneration(_ kind: CardRegenerationKind, edited: Bool) {
        if RewriteViewModel.needsOverwriteConfirmation(edited: edited) {
            pendingConfirmation = kind
        } else {
            startRegeneration(kind)
        }
    }

    private func startRegeneration(_ kind: CardRegenerationKind) {
        model.analysisController.startRegeneration(blockId: blockId, instruction: kind.instructionText)
    }

    private func cardMenu(edited: Bool, canEditText: Bool) -> some View {
        Menu {
            Button("Shorter") { requestRegeneration(.shorter, edited: edited) }
            Button("More Detailed") { requestRegeneration(.moreDetailed, edited: edited) }
            Button("Rewrite Like This…") { customInstructionText = ""; showCustomInstructionSheet = true }
            Divider()
            // "Edit Text" starts the SAME in-place editing, on the first
            // editable line of the card (one single way to edit), no longer
            // a separate blob editor. Enabling is decided from `cardData`
            // (see `hasEditableLine`), not by re-reading `context` in `body`;
            // `beginEditingFirstLine` is still protected by its `guard`.
            Button("Edit Text") { beginEditingFirstLine() }
                .disabled(!canEditText)
            if edited {
                Button("Restore Claude's Version") {
                    Task { await model.analysisController.restoreClaudeVersion(blockId: blockId) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(DSColor.textTertiary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func beginEditingFirstLine() {
        guard let items = model.analysisController.rawRewriteItems(for: blockId),
              let ref = RewriteEditText.firstLineRef(items: items) else { return }
        editingLine = RewriteLineEditingTarget(ref: ref, caret: 0)
    }
}

/// A readable line that CAN become editable in place: a single point that
/// dispatches between `MarkedTextView` (reading, with the triple-click hit
/// test) and `InlineLineEditView` (editing) for the SAME line. Every call that
/// previously built a `MarkedTextView` directly in this file was already, by
/// construction, a call for exactly one line (`RewriteItemView`/
/// `RewriteLineRowView`/`TableItemView` below), so nothing had to be
/// restructured in the rendering loops.
private struct RewriteEditableLine: View {
    let ref: RewriteEditText.LineRef
    let segments: [AnalysisController.ResolvedSegment]
    var fontSize: CGFloat
    var italic: Bool = false
    var serif: Bool = false
    let model: DocumentModel
    let blockId: String
    /// `false` for a preview-only context (Summary Lab): no triple-click hit
    /// test and no editing possible there, since it is not the real saved
    /// card.
    var isEditable: Bool = true
    @Binding var editingLine: RewriteLineEditingTarget?
    var onCommitLine: (RewriteEditText.LineRef, String, [RewriteEditText.MarkSpan]) -> Void = { _, _, _ in }

    var body: some View {
        if isEditable, editingLine?.ref == ref {
            InlineLineEditView(
                initialText: rawInitialText.text, initialSpans: rawInitialText.spans,
                initialCaret: editingLine?.caret, fontSize: fontSize, italic: italic, serif: serif,
                onSave: { text, spans in onCommitLine(ref, text, spans) },
                onCancel: { editingLine = nil }
            )
            .frame(minHeight: fontSize + 6)
        } else {
            let built = MarkedTextBuilder.build(segments)
            MarkedTextView(
                text: built.text, marks: built.marks, fontSize: fontSize, italic: italic, serif: serif,
                model: model, blockId: blockId,
                onTripleClick: isEditable ? { charIndex in editingLine = RewriteLineEditingTarget(ref: ref, caret: charIndex) } : nil,
                searchHighlightRanges: RewriteSearch.highlightRanges(model.searchQuery, in: segments)
            )
            .frame(minHeight: fontSize + 6)
        }
    }

    /// Raw text (including the `{{mX|...}}` markers) FROM DISK, not from the
    /// already-resolved segments passed in for rendering: `RewriteEditText.text`
    /// needs the markers, while `segments` has already turned them into
    /// `.marked(...)`. If the block changed under our feet between opening
    /// the editor and now (rare: another regeneration in progress), it falls
    /// back to just the visible text without marks instead of an empty editor.
    private var rawInitialText: RewriteEditText.Built {
        if let items = model.analysisController.rawRewriteItems(for: blockId),
           let built = RewriteEditText.text(for: ref, in: items) {
            return built
        }
        return RewriteEditText.Built(text: MarkedTextBuilder.build(segments).text, spans: [])
    }
}

/// A rewrite item (SPEC §5.6): dispatches on `kind`. Not `private`: reused by
/// the Summary Lab (SPEC §5.14) to draw "Current version"/"New attempt"
/// exactly like a real right-hand panel card. There it passes
/// `isEditable: false` (a preview is not the saved card, so no in-place
/// editing).
struct RewriteItemView: View {
    let item: AnalysisController.ResolvedRewriteItem
    /// Index of the item inside `cardData.rewrite`, used to build the exact
    /// `LineRef` of every line drawn below.
    var itemIndex: Int = 0
    let model: DocumentModel
    let blockId: String
    var isEditable: Bool = false
    var editingLine: Binding<RewriteLineEditingTarget?> = .constant(nil)
    var onCommitLine: (RewriteEditText.LineRef, String, [RewriteEditText.MarkSpan]) -> Void = { _, _, _ in }

    var body: some View {
        switch item.kind {
        case .summary:
            marked(item.segments ?? [], font: 13, ref: .whole(itemIndex: itemIndex))
        case .paragraph:
            marked(item.segments ?? [], font: 12.5, ref: .whole(itemIndex: itemIndex))
        case .definition:
            VStack(alignment: .leading, spacing: 6) {
                Text("DEFINITION")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(DSColor.accent)
                marked(item.segments ?? [], font: 12.5, ref: .whole(itemIndex: itemIndex))
            }
            .padding(10)
            .background(DSColor.accentBackground.opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DSColor.accentBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        case .callout:
            marked(item.segments ?? [], font: 12, ref: .whole(itemIndex: itemIndex))
                .padding(9)
                .background(DSColor.accentBackground.opacity(0.35))
                .overlay(alignment: .leading) { Rectangle().fill(DSColor.markColors(for: .arrow, hue: model.colorTheme).stroke).frame(width: 2.5) }
                .clipShape(RoundedRectangle(cornerRadius: 5))
        case .bullets:
            // Main point and sub-points are visually distinct: a different
            // symbol (filled dot vs. dash), a different indent, a different
            // text weight, and more space BETWEEN main points than between a
            // point and its sub-points, so the clustered structure (one
            // paragraph = one point plus its details) is visible at a glance
            // (SPEC quality 3.6). `subItemSegments` is absent for analyses
            // saved before this change: the layout stays identical to before
            // (no sub-points drawn).
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array((item.itemSegments ?? []).enumerated()), id: \.offset) { index, row in
                    // Real bug (seen in a screenshot): the arrow was drawn
                    // TWICE, the margin icon plus the literal "→"/"->"
                    // character at the start of the text (the prompt writes
                    // it there, SPEC §5.6). It is removed here, in a single
                    // place, rather than only hidden visually:
                    // `strippingLeadingArrowMarker` also recognizes "→"
                    // without a space and ASCII "->" (analyses saved before
                    // the prompt fix).
                    let (isArrow, cleaned) = RewriteViewModel.strippingLeadingArrowMarker(row)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 7) {
                            bulletGlyph(isArrow: isArrow)
                            // The editable line stays the RAW text of the point
                            // (with the "→ " arrow if present; no "strip" in
                            // the editor, the same choice as the earlier blob
                            // editor): `marked(cleaned,...)` below is for
                            // READING only, while editing uses `ref` to re-read
                            // the raw field from `RewriteEditText`.
                            marked(cleaned, font: 12.5, ref: .bulletMain(itemIndex: itemIndex, index: index))
                        }
                        let subRows = (item.subItemSegments?.indices.contains(index) == true) ? item.subItemSegments![index] : []
                        if !subRows.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(subRows.enumerated()), id: \.offset) { subIndex, subRow in
                                    let (subIsArrow, subCleaned) = RewriteViewModel.strippingLeadingArrowMarker(subRow)
                                    HStack(alignment: .top, spacing: 6) {
                                        subBulletGlyph(isArrow: subIsArrow)
                                        marked(subCleaned, font: 11.5, ref: .bulletSub(itemIndex: itemIndex, index: index, subIndex: subIndex))
                                    }
                                }
                            }
                            .padding(.leading, 19)
                        }
                    }
                }
            }
        case .steps:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array((item.itemSegments ?? []).enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(index + 1).")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DSColor.accent)
                            .frame(width: 16, alignment: .leading)
                        marked(row, font: 12.5, ref: .step(itemIndex: itemIndex, index: index))
                    }
                }
            }
        case .table:
            TableItemView(columns: item.columns ?? [], rowSegments: item.rowSegments ?? [], itemIndex: itemIndex, model: model, blockId: blockId, isEditable: isEditable, editingLine: editingLine, onCommitLine: onCommitLine)
        case .outline:
            // One line type for each line of the rewrite, rendered distinctly and
            // "consistent with the look of the Word style": indent/symbol for
            // point/sub-point (same visual language as `.bullets` above),
            // italic for note/explanation, a different typeface and a box for
            // formula, a bold subheading without a symbol.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((item.lines ?? []).enumerated()), id: \.offset) { index, line in
                    RewriteLineRowView(line: line, itemIndex: itemIndex, index: index, model: model, blockId: blockId, isEditable: isEditable, editingLine: editingLine, onCommitLine: onCommitLine)
                }
            }
        }
    }

    /// SPEC §5.6 "the → arrow indicates cause and effect": a line that starts
    /// with "→"/"->" (`RewriteViewModel.strippingLeadingArrowMarker`, already
    /// removed from the displayed text) uses an arrow instead of the dot.
    @ViewBuilder
    private func bulletGlyph(isArrow: Bool) -> some View {
        if isArrow {
            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(DSColor.markColors(for: .arrow, hue: model.colorTheme).stroke).padding(.top, 3)
        } else {
            Circle().fill(DSColor.markColors(for: .rectangle, hue: model.colorTheme).stroke).frame(width: 5, height: 5).padding(.top, 6)
        }
    }

    /// Sub-point symbol, different from the main point's (a small dash instead
    /// of a filled dot/arrow). SPEC quality 3.6 "points and sub-points visually
    /// distinct: different indent, symbol and weight".
    @ViewBuilder
    private func subBulletGlyph(isArrow: Bool) -> some View {
        if isArrow {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 8)).foregroundStyle(DSColor.markColors(for: .arrow, hue: model.colorTheme).stroke.opacity(0.85)).padding(.top, 2)
        } else {
            Rectangle().fill(DSColor.textTertiary).frame(width: 5, height: 1.4).padding(.top, 8)
        }
    }

    private func marked(_ segments: [AnalysisController.ResolvedSegment], font: CGFloat, ref: RewriteEditText.LineRef) -> some View {
        RewriteEditableLine(ref: ref, segments: segments, fontSize: font, model: model, blockId: blockId, isEditable: isEditable, editingLine: editingLine, onCommitLine: onCommitLine)
    }
}

/// A `kind == .outline` line: the symbol/indent/emphasis depend on the
/// `RewriteLineType` and do not touch `MarkedTextView` (markers/marks are
/// still resolved as everywhere else). A dedicated view (not one more `case`
/// inside `RewriteItemView.body`) because each type has its own box/indent/
/// font; keeping them here avoids weighing down the main `switch`.
private struct RewriteLineRowView: View {
    let line: AnalysisController.ResolvedLine
    let itemIndex: Int
    let index: Int
    let model: DocumentModel
    let blockId: String
    var isEditable: Bool = false
    var editingLine: Binding<RewriteLineEditingTarget?> = .constant(nil)
    var onCommitLine: (RewriteEditText.LineRef, String, [RewriteEditText.MarkSpan]) -> Void = { _, _, _ in }

    private var ref: RewriteEditText.LineRef { .outlineLine(itemIndex: itemIndex, index: index) }

    var body: some View {
        switch line.type {
        case .point:
            HStack(alignment: .top, spacing: 7) {
                Circle().fill(DSColor.markColors(for: .rectangle, hue: model.colorTheme).stroke).frame(width: 5, height: 5).padding(.top, 6)
                text(font: 12.5)
            }
        case .consequence:
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(DSColor.markColors(for: .arrow, hue: model.colorTheme).stroke).padding(.top, 3)
                text(font: 12.5)
            }
        case .subpoint:
            HStack(alignment: .top, spacing: 6) {
                Rectangle().fill(DSColor.textTertiary).frame(width: 5, height: 1.4).padding(.top, 8)
                text(font: 11.5)
            }
            .padding(.leading, 19)
        case .explanation:
            // Bullet explanation (styleId `Spiegazionebullet`, "Spiegazione
            // bullet"): italic, no symbol, same indent as the sub-point (a
            // line of prose right under the point it explains).
            text(font: 11, italic: true)
                .foregroundStyle(DSColor.textSecondary)
                .padding(.leading, 19)
        case .note:
            // styleId `Nota`: amber left border (same color as the Word
            // template, FFC000), italic note text.
            text(font: 12, italic: true)
                .padding(9)
                .background(Color(red: 1, green: 0.753, blue: 0).opacity(0.08))
                .overlay(alignment: .leading) { Rectangle().fill(Color(red: 1, green: 0.753, blue: 0)).frame(width: 2.5) }
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .formula:
            // styleId `Formula`: box on all 4 sides, centered, italic, a
            // different typeface from the body (serif).
            text(font: 12.5, italic: true, serif: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.086, green: 0.376, blue: 0.510), lineWidth: 1))
        case .definition:
            // styleId `Definizione`: blue-green left border (as in the Word
            // style, 156082), normal text; quiet, the same shape as the note
            // with another color.
            text(font: 12)
                .padding(9)
                .background(Color(red: 0.086, green: 0.376, blue: 0.510).opacity(0.07))
                .overlay(alignment: .leading) { Rectangle().fill(Color(red: 0.086, green: 0.376, blue: 0.510)).frame(width: 2.5) }
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .example:
            // styleId `Example`: dark gray left border, italic and smaller,
            // no background (the least conspicuous of the boxes).
            text(font: 11, italic: true)
                .foregroundStyle(DSColor.textSecondary)
                .padding(.vertical, 4)
                .padding(.leading, 9)
                .overlay(alignment: .leading) { Rectangle().fill(DSColor.textTertiary).frame(width: 2.5) }
        case .subheading:
            // styleId `GrassoTitoli` ("Grasso Titoli"): a rare subheading,
            // bold, NOT in the contents, only a quiet divider inside the card
            // (an author decision).
            text(font: 11.5)
                .padding(.top, 4)
        case .other:
            // Unknown type (future schema): rendered as a plain point instead of
            // disappearing, never a crash on a value we do not recognize yet
            // (same principle as `BlockAnalysisStatus.other`).
            text(font: 12.5)
        }
    }

    private func text(font: CGFloat, italic: Bool = false, serif: Bool = false) -> some View {
        RewriteEditableLine(ref: ref, segments: line.segments, fontSize: font, italic: italic, serif: serif, model: model, blockId: blockId, isEditable: isEditable, editingLine: editingLine, onCommitLine: onCommitLine)
    }
}

/// Mini table (SPEC §5.6, at most 4 columns × 8 rows, already enforced by
/// `AnalysisPostProcessor`). Each cell is an editable line of its own
/// (`LineRef.tableCell`); columns are not editable here (unchanged).
private struct TableItemView: View {
    let columns: [String]
    let rowSegments: [[[AnalysisController.ResolvedSegment]]]
    let itemIndex: Int
    let model: DocumentModel
    let blockId: String
    var isEditable: Bool = false
    var editingLine: Binding<RewriteLineEditingTarget?> = .constant(nil)
    var onCommitLine: (RewriteEditText.LineRef, String, [RewriteEditText.MarkSpan]) -> Void = { _, _, _ in }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            if !columns.isEmpty {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        Text(column).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(DSColor.textSecondary)
                    }
                }
                Divider()
            }
            ForEach(Array(rowSegments.enumerated()), id: \.offset) { row, cells in
                GridRow {
                    ForEach(Array(cells.enumerated()), id: \.offset) { col, cell in
                        RewriteEditableLine(
                            ref: .tableCell(itemIndex: itemIndex, row: row, col: col), segments: cell, fontSize: 11.5,
                            model: model, blockId: blockId, isEditable: isEditable, editingLine: editingLine, onCommitLine: onCommitLine
                        )
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
