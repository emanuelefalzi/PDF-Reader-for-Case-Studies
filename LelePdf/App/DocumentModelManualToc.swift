import Foundation
@preconcurrency import PDFKit

/// Manual T1-T4 contents (SPEC v2.3 §5.3, §8; M7):
/// `DocumentModel` commands for the mini selection bar (§5.7) and the
/// context menu of the Chapters tree. Kept in a file separate from
/// `DocumentModel.swift` to keep files short.
@MainActor
extension DocumentModel {
    /// Mini selection bar (§5.7): "T1"/"T2"/"T3"/"T4" on the current PDF
    /// selection. Now synchronous and undoable with ⌘Z
    /// (`applyTocEntriesEdit`), instead of the earlier round trip through the
    /// Store, with the same effect on the tree and no visible wait.
    func addManualTocEntry(selection: PDFSelection, level: Int) {
        guard let piece = manualTocPiece(from: selection) else { return }
        applyTocShortcut(pieces: [piece], level: level, actionName: "add heading")
    }

    /// ⌘⌥1…4: the multiple selection
    /// (`multiSelectionPieces`) takes precedence if it is not empty: one
    /// piece per entry, a single edit undoable with a single ⌘Z
    /// (`ManualTocShortcut.apply`/`applyTocEntriesEdit`); otherwise the
    /// current single selection in the PDF, with the same "already an entry
    /// -> change level, otherwise add" behavior as `ManualTocShortcut`.
    func applyTocLevelShortcut(level: Int) {
        let level = max(1, min(4, level))
        if !multiSelectionPieces.isEmpty {
            let pieces = multiSelectionPieces.compactMap { manualTocPiece(from: $0) }
            guard !pieces.isEmpty else { return }
            applyTocShortcut(pieces: pieces, level: level, actionName: "set heading level (multiple)")
            clearMultiSelection()
            return
        }
        guard let selection = readerBridge?.currentSelection, let piece = manualTocPiece(from: selection) else { return }
        applyTocShortcut(pieces: [piece], level: level, actionName: "set heading level")
    }

    private func applyTocShortcut(pieces: [ManualTocShortcut.Piece], level: Int, actionName: String) {
        let before = documentRecord?.toc.entries ?? []
        let after = ManualTocShortcut.apply(pieces: pieces, level: level, entries: before)
        applyTocEntriesEdit(TocEntriesEdit(before: before, after: after), actionName: actionName)
    }

    private func manualTocPiece(from selection: PDFSelection) -> ManualTocShortcut.Piece? {
        guard let page = selection.pages.first else { return nil }
        let pageIndex = pdfDocument.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        let title = ManualToc.cleanTitle(selection.string ?? "")
        guard !title.isEmpty else { return nil }
        let pageY = ManualSelectionResolver.pageY(of: selection, onPage: page)
        return ManualTocShortcut.Piece(page: pageIndex, title: title, pageY: pageY)
    }

    /// Tree context menu (§5.3): "Change level" (T1-T4). Same
    /// synchronous/undoable path as `addManualTocEntry`.
    func changeTocEntryLevel(id: String, level: Int) {
        var after = documentRecord?.toc.entries ?? []
        let before = after
        ManualToc.changeLevel(id: id, to: level, entries: &after)
        applyTocEntriesEdit(TocEntriesEdit(before: before, after: after), actionName: "change heading level")
    }

    /// Tree context menu (§5.3): "Rename". Same synchronous and undoable path
    /// as "Change level"/⌘⌥1…4; it used to go through an asynchronous round
    /// trip with the Store outside the ⌘Z stack, so a ⌘Z on an entry added
    /// BEFORE the rename brought the whole list back to how it was and also
    /// undid the rename, and `refreshAnalysisContext` wiped the ⌘Z history of
    /// the marks.
    func renameTocEntry(id: String, title: String) {
        let cleaned = ManualToc.cleanTitle(title)
        guard !cleaned.isEmpty else { return }
        var after = documentRecord?.toc.entries ?? []
        let before = after
        ManualToc.rename(id: id, to: cleaned, entries: &after)
        applyTocEntriesEdit(TocEntriesEdit(before: before, after: after), actionName: "rename heading")
    }

    /// Tree context menu (§5.3): "Remove". The entry becomes a manual
    /// tombstone (`removed: true`) so "Regenerate Contents" does not bring it
    /// back. The same holds for a hand-added entry: it stays invisible but
    /// the user's decision survives future automatic deduplication.
    /// Synchronous and undoable like `renameTocEntry`.
    func removeTocEntry(id: String) {
        var after = documentRecord?.toc.entries ?? []
        let before = after
        ManualToc.remove(id: id, entries: &after)
        applyTocEntriesEdit(TocEntriesEdit(before: before, after: after), actionName: "remove heading")
    }

    /// Empties the accumulated multiple selection (consumed by ⌘⌥1…4, by a
    /// click without ⌘, or by Esc; `MarksOverlayMultiSelection.swift`).
    func clearMultiSelection() {
        multiSelectionPieces = []
    }

    /// Publishes `tocEntries`/`tocSource` for the UI (SPEC §5.3) from a
    /// `TocRecord`: filters out the tombstones (`ManualToc.visible`) and sorts
    /// by position in the document (`ManualToc.sorted`), the same point used
    /// by `attachStructureToStore`/`regenerateToc` in `DocumentModel.swift`,
    /// so the contents shown is always consistent with the saved one.
    func applyTocRecord(_ toc: TocRecord) {
        let visible = ManualToc.sorted(ManualToc.visible(toc.entries))
        tocEntries = visible.map { TocEntry(id: $0.id, title: $0.title, level: $0.level, page: $0.page, origin: $0.origin, pageY: $0.pageY) }
        tocSource = toc.source == .generated ? .generated : .native
    }

    /// After `tocEntries` has been replaced by a regenerated contents
    /// (`startTocGeneration`), whose "gen-N" ids are positional and change
    /// entry, the collapsed state and the pin follow the entries by
    /// page+title (`ManualToc.idRemap`); whatever no longer finds an entry is
    /// dropped, instead of staying on an id that now points to a different
    /// title. For the same reason the manual contents' ⌘Z history is no
    /// longer valid: a later ⌘Z would have restored the WHOLE list from
    /// before the regeneration (`TocEntriesEdit.before`), wiping the new
    /// contents.
    func reconcileTocEntryState(previousEntries: [TocEntry]) {
        let remap = ManualToc.idRemap(from: previousEntries, to: tocEntries)
        let collapsed = Set(collapsedTocEntryIds.compactMap { remap[$0] })
        if collapsed != collapsedTocEntryIds { setCollapsedTocEntryIds(collapsed) }
        if let pinnedTocEntryID { self.pinnedTocEntryID = remap[pinnedTocEntryID] }
        invalidateTocUndoHistory()
    }
}
