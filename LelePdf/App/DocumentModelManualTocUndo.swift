import Foundation

/// Undo/redo of the manual contents ("undoable with ⌘Z"): same
/// pattern as `ManualMarksUndo.swift`/`AnnotationUndoStack`. One "unit" is
/// the whole `[TocEntryRecord]` array before/after (simpler and more
/// robust than a per-entry diff: a single operation can touch several
/// entries at once, "a single operation undoable with a single ⌘Z" for the
/// multiple selection).
struct TocEntriesEdit: Sendable, Equatable {
    var before: [TocEntryRecord]
    var after: [TocEntryRecord]

    /// "Change level"/"Rename"/⌘⌥1…4 on an automatic entry give it a NEW id
    /// ("manual-N") and leave the old one as a tombstone
    /// (`ManualToc.editEntry`): the collapsed state and the pin, kept by id,
    /// would stay on the invisible tombstone, so renaming a collapsed chapter
    /// expanded it. Here we derive, from the before/after alone, which new id
    /// takes the place of which old id: a tombstone that has just appeared
    /// and the visible entry that has just appeared with the same position
    /// (page, `pageY`) and the same title (level change) or the same level
    /// (rename). Empty for an addition or a removal.
    var idRemap: [String: String] {
        let beforeById = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newVisible = after.filter { $0.removed != true && beforeById[$0.id] == nil }
        guard !newVisible.isEmpty else { return [:] }
        var remap: [String: String] = [:]
        var taken: Set<String> = []
        for tombstone in after where tombstone.removed == true && beforeById[tombstone.id]?.removed != true && beforeById[tombstone.id] != nil {
            if let match = newVisible.first(where: {
                !taken.contains($0.id) && $0.page == tombstone.page && $0.pageY == tombstone.pageY
                    && ($0.title == tombstone.title || $0.level == tombstone.level)
            }) {
                remap[tombstone.id] = match.id
                taken.insert(match.id)
            }
        }
        return remap
    }
}

struct ManualTocUndoStack {
    private(set) var undoStack: [TocEntriesEdit] = []
    private(set) var redoStack: [TocEntriesEdit] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func record(_ edit: TocEntriesEdit) {
        undoStack.append(edit)
        redoStack.removeAll()
    }

    mutating func popUndo() -> TocEntriesEdit? {
        guard let edit = undoStack.popLast() else { return nil }
        redoStack.append(edit)
        return edit
    }

    mutating func popRedo() -> TocEntriesEdit? {
        guard let edit = redoStack.popLast() else { return nil }
        undoStack.append(edit)
        return edit
    }

    mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

/// Bridge to the window's REAL `UndoManager` (the same
/// `analysisController.undoManager` used for marks/annotations, so
/// ⌘Z/⇧⌘Z also interleaves the manual contents entries in the real order
/// of actions). Kept in a file separate from `DocumentModelManualToc.swift`
/// to keep files short.
@MainActor
extension DocumentModel {
    /// Applies an already computed array of entries (synchronous: no round
    /// trip to the Store is needed, `documentRecord` is already in memory):
    /// immediately publishes `tocEntries` for the UI, records the change on
    /// the pure stack, arms ONE undo entry, and writes to the Store in the
    /// background (same "fire and forget" pattern as
    /// `AnalysisController.apply`).
    func applyTocEntriesEdit(_ edit: TocEntriesEdit, actionName: String) {
        guard edit.before != edit.after else { return }
        applyTocEntriesLocally(edit.after)
        remapTocEntryState(edit.idRemap)
        manualTocUndoStack.record(edit)
        armTocSystemUndo(actionName: actionName)
        persistTocEntries(edit.after)
    }

    /// Carries the collapsed state and the pin from the old ids to the new
    /// ones (`TocEntriesEdit.idRemap`); on undo the inverse map is applied, so
    /// a collapsed chapter stays collapsed even after "Rename" and after its
    /// ⌘Z.
    private func remapTocEntryState(_ remap: [String: String]) {
        guard !remap.isEmpty else { return }
        let collapsed = Set(collapsedTocEntryIds.map { remap[$0] ?? $0 })
        if collapsed != collapsedTocEntryIds { setCollapsedTocEntryIds(collapsed) }
        if let pinnedTocEntryID, let mapped = remap[pinnedTocEntryID] { self.pinnedTocEntryID = mapped }
    }

    /// After "Regenerate Contents" the manual contents' ⌘Z stack describes
    /// lists that no longer exist (see `reconcileTocEntryState`): the pure
    /// stack is emptied and only the entries registered with THIS target are
    /// removed from the window's `UndoManager` (`DocumentModel` registers
    /// only contents changes; marks and annotations use
    /// `AnalysisController`/`AnnotationController` as their target and stay
    /// undoable).
    func invalidateTocUndoHistory() {
        manualTocUndoStack.removeAll()
        analysisController.undoManager?.removeAllActions(withTarget: self)
    }

    private func armTocSystemUndo(actionName: String) {
        analysisController.undoManager?.registerUndo(withTarget: self) { target in
            if target.performTocUndo() { target.armTocSystemRedo(actionName: actionName) }
        }
        analysisController.undoManager?.setActionName(actionName)
    }

    private func armTocSystemRedo(actionName: String) {
        analysisController.undoManager?.registerUndo(withTarget: self) { target in
            if target.performTocRedo() { target.armTocSystemUndo(actionName: actionName) }
        }
        analysisController.undoManager?.setActionName(actionName)
    }

    /// Synchronous (called from the `UndoManager.registerUndo` handler, which
    /// cannot wait for an `async`; same pattern as
    /// `AnalysisController.performManualMarkUndo`); the real write to the
    /// Store stays a detached `Task` inside `persistTocEntries`.
    @discardableResult
    func performTocUndo() -> Bool {
        guard let edit = manualTocUndoStack.popUndo() else { return false }
        applyTocEntriesLocally(edit.before)
        let inverse = Dictionary(edit.idRemap.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        remapTocEntryState(inverse)
        persistTocEntries(edit.before)
        return true
    }

    @discardableResult
    func performTocRedo() -> Bool {
        guard let edit = manualTocUndoStack.popRedo() else { return false }
        applyTocEntriesLocally(edit.after)
        remapTocEntryState(edit.idRemap)
        persistTocEntries(edit.after)
        return true
    }

    /// Immediately publishes `tocEntries`/`documentRecord.toc.entries` (same
    /// visibility/ordering rule as `applyTocRecord`), without waiting for the
    /// write to the Store. It also updates the entries seen by the analysis
    /// (card labels such as "3.2", titles between cards, chapter scope):
    /// previously ⌘⌥1…4/"Change level" left `AnalysisController` on the old
    /// contents until the next `refreshAnalysisContext`, while
    /// "Rename"/"Remove" redid it entirely (wiping the marks' ⌘Z history).
    private func applyTocEntriesLocally(_ entries: [TocEntryRecord]) {
        documentRecord?.toc.entries = entries
        let source = documentRecord?.toc.source ?? .native
        applyTocRecord(TocRecord(source: source, entries: entries))
        analysisController.updateTocEntries(tocEntries)
    }

    private func persistTocEntries(_ entries: [TocEntryRecord]) {
        guard let storeFingerprint else { return }
        Task {
            await AppStore.shared.updateTocEntries(fingerprint: storeFingerprint) { $0 = entries }
        }
    }
}
