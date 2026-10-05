import SwiftUI

/// Makes the `DocumentModel` of the frontmost window reachable from the
/// menu commands (SPEC §5.1: shortcuts act on the active window).
private struct DocumentModelFocusedValueKey: FocusedValueKey {
    typealias Value = DocumentModel
}

extension FocusedValues {
    var documentModel: DocumentModel? {
        get { self[DocumentModelFocusedValueKey.self] }
        set { self[DocumentModelFocusedValueKey.self] = newValue }
    }
}

/// Replaces the generic Save of `DocumentGroup(viewing:)` with the
/// explicit command. ⌘S never goes through the read-only file wrapper:
/// it directly calls the protected PDF write.
struct PDFSaveCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save the marks in the PDF") { model?.saveMarksIntoPDF() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model?.canWriteOriginalPDF != true || model?.pdfSaveState == .saving)
        }
    }
}

/// Shortcuts from M1 (SPEC §5.1): ⌘F search, ⌘⌥1 sidebar, ⌘⌥2 right
/// panel (later replaced by ⌘⇧1/⌘⇧2, see the comment on
/// "Sidebar"/"Right Panel" below), ⌥⌘L "Follow the PDF", ⌘+/⌘−
/// zoom, ⌘0 actual size (optional per the spec, added here because it
/// costs little). ⌘J chat and ⌘↩ analyze are left to the milestones that
/// introduce those features (M9, M5). ⌘O and Open Recent come for free
/// from `DocumentGroup`.
struct DocumentCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            // Also disabled while a row of the right panel is being edited in place
            // (`isSearchAvailable`, "works from any focus except inside an inline
            // edit"), not only `model == nil`.
            Button("Search") { model?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model?.isSearchAvailable != true)

            // SPEC §5.10 "↩/⌘G next, ⇧↩/⇧⌘G previous": ⏎/⇧⏎ stay local to the
            // field (`SearchFieldView`), ⌘G/⇧⌘G must work "with focus anywhere", so
            // they go through a real menu command instead of an `onKeyPress` tied
            // to the field.
            Button("Find Next") { model?.searchNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model?.isSearchAvailable != true || model?.searchTotalCount == 0)

            Button("Find Previous") { model?.searchPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model?.isSearchAvailable != true || model?.searchTotalCount == 0)

            Button("Ask the PDF") { model?.toggleChat() }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(model == nil)

            // A single Esc command: if chat and map are both open, two entries with
            // the same shortcut compete and AppKit executes only one. The single
            // action closes both, as SPEC §5.1 asks, and stays disabled without
            // overlaps.
            Button("Close chat and map") { model?.closeTransientOverlays() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(model?.hasTransientOverlay != true)

            Divider()

            // Explicit request from the user: "I'd like to use cmd+option+1 to open
            // and close the menu on the left, and cmd+option+2 for the one on the
            // right". They replace M1's ⌃⌘S/⌥⌘I instead of sitting alongside them:
            // two shortcuts for the SAME action would have meant two rows for the
            // same command in the View menu, confusing for no reason
            // (`MenuCommandTable`: every command visible in a menu, one command, one
            // entry). State remembered per app in `PaneWidthStore`
            // (`DocumentModel.sidebarVisible`/`rightPanelVisible`, above), like the
            // widths of the two panels.
            // Later moved to ⌘⇧1/⌘⇧2 to free ⌘⌥1…4 for the T1-T4 headings.
            Button("Sidebar") { model?.toggleSidebar() }
                .keyboardShortcut("1", modifiers: [.command, .shift])
                .disabled(model == nil)

            Button("Right Panel") { model?.toggleRightPanel() }
                .keyboardShortcut("2", modifiers: [.command, .shift])
                .disabled(model == nil)

            Button("Follow the PDF") { model?.followPDF.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model == nil)

            // The legend is collapsible (it appears when the cursor approaches the
            // sidebar's left edge); this entry is the keyboard/menu way to make it
            // appear without the mouse.
            Button("Legend") { model?.legendForcedVisible.toggle() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(model == nil)

            // SPEC §5.13 "Markup toolbar ... shortcut ⇧⌘A (as in Preview)".
            Button("Annotation Toolbar") { model?.annotationController.barVisible.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Zoom In") { model?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(model == nil)

            Button("Zoom Out") { model?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(model == nil)

            Button("Actual Size") { model?.zoomActualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(model == nil)
        }
    }
}

@MainActor
extension DocumentModel {
    /// Extended to include the active search: a single Esc command, the same
    /// principle already chosen for chat/map ("two entries with the same
    /// shortcut compete and AppKit executes only one").
    // Brief "the selection is cancelled ... with Esc": the same single Esc
    // command as above, not a second menu entry with the same shortcut.
    var hasTransientOverlay: Bool {
        chatController.isPresented || mapExpanded || !searchQuery.isEmpty || !multiSelectionPieces.isEmpty
    }

    /// ONLY what draws ABOVE the reader in the same `ZStack` (chat, expanded
    /// map) blocks pointer gestures on the PDF (⌃+wheel/pinch,
    /// `PDFReaderCoordinator+WheelZoom`). `hasTransientOverlay` above is the
    /// list of what Esc closes, and it was widened to open search and
    /// multiple selection: reusing it for the zoom monitor (written when it
    /// contained only chat and map) turned zoom off while search was open or
    /// while a selection was being accumulated with ⌘, two things that do
    /// not cover the PDF.
    var readerGesturesBlockedByOverlay: Bool {
        chatController.isPresented || mapExpanded
    }

    func closeTransientOverlays() {
        chatController.closePanel()
        closeExpandedMap()
        if !searchQuery.isEmpty { closeSearch() }
        if !multiSelectionPieces.isEmpty {
            clearMultiSelection()
            readerBridge?.clearSelection()
        }
    }
}

/// "Analysis" menu (SPEC §5.1 point 2 "Actions menu removed", §5.5 "⌘↩
/// analyze the next block", M5b deliverable 6): no generic "Actions"
/// menu, only this dedicated command.
struct AnalysisCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        CommandMenu("Analysis") {
            Button("Analyze the Next Block") {
                guard let model else { return }
                model.analysisController.analyzeNext(fromReadingPosition: model.analysisController.readingPositionBlock(currentPageIndex: model.currentPageIndex))
            }
            .keyboardShortcut(.return, modifiers: .command)
            // Disabled while a row of the right panel is being edited in place: ⌘↩
            // is a real menu shortcut key, evaluated BEFORE the event reaches the
            // `first responder` (the row being edited); the only correct way to let
            // it "fall through" to there is to disable the entry.
            .disabled(model == nil || model?.analysisController.isEditingAnyLine == true)
        }
    }
}
