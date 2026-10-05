import Foundation

/// Manual marks/links and card text editing (SPEC §5.6, §5.7): an extension
/// of `AnalysisController`, kept separate to keep files small.
@MainActor
extension AnalysisController {
    /// SPEC §5.7 "Add": new manual mark on the selection already resolved by
    /// `ManualSelectionResolver` (block + range in the clean text). Also
    /// allowed on a block not yet analyzed: the `analisi.json` entry for that
    /// block, if it does not already exist, is created with
    /// `status: .other("manual")`, never `.analyzed`, so `blockState(_:)` keeps
    /// seeing `.idle`/the "Analyze this section" pill unchanged until Claude
    /// really analyzes it (SPEC: make sure placeholders/progress aren't
    /// confused).
    func addManualMark(blockId: String, type: MarkType, text: String, page: Int, cleanRange: NSRange) async {
        guard let context, let block = context.blocks.first(where: { $0.id == blockId }) else { return }
        let before = context.analysis.blocks[blockId]
        var current = before ?? BlockAnalysis(status: .other("manual"))
        let (mark, newTerm) = ManualMarks.makeMark(
            text: text, type: type, page: page, range: MarkRange(start: cleanRange.location, length: cleanRange.length),
            blockId: blockId, existingTerms: context.analysis.terms, existingMarks: current.marks
        )
        current.marks.append(mark)
        recomputeLinks(&current, block: block)
        let edit = ManualMarkEdit(
            blockId: blockId, beforeBlock: before, afterBlock: current,
            termId: newTerm?.id, beforeTerm: nil, afterTerm: newTerm?.record
        )
        await apply(edit, actionName: "add mark")
    }

    /// SPEC §5.7 "Change": updates the type of an existing mark (Claude's or
    /// manual: clicking an existing mark shows the same bar with "Change").
    /// The original `source` does not change, only the type: SPEC does not ask
    /// to "adopt" a Claude mark by recoloring it, and the hide/delete rule of
    /// "Remove" stays the one of the real source.
    func changeMarkType(blockId: String, markId: String, newType: MarkType) async {
        guard let context, let block = context.blocks.first(where: { $0.id == blockId }),
              let before = context.analysis.blocks[blockId],
              let index = before.marks.firstIndex(where: { $0.id == markId }) else { return }
        var current = before
        current.marks[index].type = newType
        recomputeLinks(&current, block: block)
        let edit = ManualMarkEdit(blockId: blockId, beforeBlock: before, afterBlock: current, termId: nil, beforeTerm: nil, afterTerm: nil)
        await apply(edit, actionName: "change mark type")
    }

    /// SPEC §5.7 "Claude marks removed: they are hidden, not deleted ... they
    /// also disappear from the map"; a manual mark is really deleted.
    func removeMark(blockId: String, markId: String) async {
        guard let context, let block = context.blocks.first(where: { $0.id == blockId }),
              let before = context.analysis.blocks[blockId],
              let index = before.marks.firstIndex(where: { $0.id == markId }) else { return }
        var current = before
        if current.marks[index].source == .claude {
            current.marks[index].hidden = true
        } else {
            current.marks.remove(at: index)
        }
        recomputeLinks(&current, block: block)
        let edit = ManualMarkEdit(blockId: blockId, beforeBlock: before, afterBlock: current, termId: nil, beforeTerm: nil, afterTerm: nil)
        await apply(edit, actionName: "remove mark")
    }

    private func recomputeLinks(_ analysis: inout BlockAnalysis, block: TextBlock) {
        analysis.links = ManualLinkDerivation.recomputeManualLinks(existingLinks: analysis.links, marks: analysis.marks, cleanText: block.cleanText)
    }

    // MARK: - Undo/redo (SPEC §5.7)

    /// Applies an already computed change, records it on the pure stack and
    /// arms ONE undo entry on the system `UndoManager`: the same pattern as
    /// `AnnotationController.apply`/`armSystemUndo`/`armSystemRedo`, on the
    /// same window `UndoManager` (set by `MarksOverlayView.viewDidMoveToWindow`),
    /// so ⌘Z/⇧⌘Z interleave manual marks and annotations in the real order of
    /// actions.
    private func apply(_ edit: ManualMarkEdit, actionName: String) async {
        applyLocalChange(
            blockId: edit.blockId, blockAnalysis: edit.afterBlock,
            termId: edit.termId, term: edit.afterTerm,
            resetManualMarkUndo: false
        )
        manualMarksUndoStack.record(edit)
        armSystemUndo(actionName: actionName)
        guard let fingerprint = context?.fingerprint else { return }
        await enqueuePersistence(
            fingerprint: fingerprint, blockId: edit.blockId,
            blockAnalysis: edit.afterBlock, termId: edit.termId, term: edit.afterTerm
        ).value
    }

    /// `UndoManager.registerUndo(withTarget:handler:)` wants a SYNCHRONOUS
    /// handler; `performManualMarkUndo`/`performManualMarkRedo` are (see
    /// there): the same pattern as `AnnotationController.armSystemUndo`.
    private func armSystemUndo(actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            if target.performManualMarkUndo() {
                target.armSystemRedo(actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
    }

    private func armSystemRedo(actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            if target.performManualMarkRedo() {
                target.armSystemUndo(actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Undoes the last change on the pure stack (called by the system
    /// `UndoManager`, but also testable on its own without AppKit: tests at the
    /// controller level). SYNCHRONOUS (unlike `apply`/`applyChange`, used by the
    /// forward path): `UndoManager.registerUndo` wants a `(Target) -> Void`
    /// handler, it cannot wait for an `async`. The same pattern is already used
    /// for annotations (`AnnotationController.performUndo`/`persist`, also
    /// synchronous, with the Store updated by a detached `Task`).
    @discardableResult
    func performManualMarkUndo() -> Bool {
        guard let edit = manualMarksUndoStack.popUndo() else { return false }
        applyChangeFireAndForget(blockId: edit.blockId, blockAnalysis: edit.beforeBlock, termId: edit.termId, term: edit.beforeTerm)
        return true
    }

    @discardableResult
    func performManualMarkRedo() -> Bool {
        guard let edit = manualMarksUndoStack.popRedo() else { return false }
        applyChangeFireAndForget(blockId: edit.blockId, blockAnalysis: edit.afterBlock, termId: edit.termId, term: edit.afterTerm)
        return true
    }

    // MARK: - Text editing (SPEC §5.6 "Edit text")

    /// Saves a manual edit of a card's text: **no call to Claude**.
    /// `editedText`/`editedSpans` come from `EditableMarkedNSTextView` after
    /// the user's edit; `RewriteEditText.parse` converts them back into
    /// `[RewriteItem]` with the `{{mX|...}}` markers rebuilt. A mark whose id no
    /// longer appears in any surviving marker has had "its text disappear" from
    /// the rewrite (SPEC §5.6): hidden if Claude's, deleted if manual, the same
    /// rule as `removeMark`. The `range`/`page`/`text` of a mark that SURVIVES
    /// never change here (they remain the occurrence in the PDF): only the text
    /// shown in the marker changes.
    func saveManualEdit(blockId: String, editedText: String, editedSpans: [RewriteEditText.MarkSpan]) async {
        guard var current = context?.analysis.blocks[blockId] else { return }
        // Only the marks that were really present in the editor can have been
        // deleted by the user. Manual marks highlighted at render time only,
        // and PDF marks that Claude did not cite in the rewrite, have no
        // editable span: treating them as "gone" would delete them on the
        // first save of any other word.
        let originallyEditableIds = Set(RewriteEditText.render(items: current.rewrite).spans.map(\.markId))
        let newItems = RewriteEditText.parse(text: editedText, spans: editedSpans, originalItems: current.rewrite)
        let survivingIds = Set(editedSpans.map(\.markId))
        let removedIds = originallyEditableIds.subtracting(survivingIds)
        for index in current.marks.indices where removedIds.contains(current.marks[index].id) {
            if current.marks[index].source == .claude { current.marks[index].hidden = true }
        }
        current.marks.removeAll { $0.source == .manual && removedIds.contains($0.id) }
        current.rewrite = newItems
        current.rewriteEdited = true
        await applyChange(blockId: blockId, blockAnalysis: current, termId: nil, term: nil)
    }

    /// Saves an in-place edit of ONE SINGLE row of the card: the same principle
    /// as `saveManualEdit` above (no call to Claude, `{{mX|...}}` markers
    /// rebuilt locally, a mark whose id disappears from the row follows the
    /// hide/delete rule of `removeMark`), but the set of "originally editable"
    /// ids comes ONLY from the touched row (`RewriteEditText.text(for:in:)`),
    /// not from the whole card: a mark in another row/item is never a
    /// candidate for removal here, regardless of what it currently contains.
    /// It goes through `apply(_:actionName:)`, not `applyChange` (used by
    /// `saveManualEdit`/`restoreClaudeVersion`, which were never connected to
    /// the system `UndoManager`), so a row edit joins the SAME
    /// stack/`UndoManager` as manual marks, and ⌘Z undoes it like any other
    /// panel change.
    func saveManualEditLine(blockId: String, ref: RewriteEditText.LineRef, editedText: String, editedSpans: [RewriteEditText.MarkSpan]) async {
        guard let before = context?.analysis.blocks[blockId],
              let beforeLine = RewriteEditText.text(for: ref, in: before.rewrite) else { return }
        var current = before
        var newItems = current.rewrite
        RewriteEditText.apply(text: editedText, spans: editedSpans, to: ref, items: &newItems)
        let originallyEditableIds = Set(beforeLine.spans.map(\.markId))
        let survivingIds = Set(editedSpans.map(\.markId))
        let removedIds = originallyEditableIds.subtracting(survivingIds)
        for index in current.marks.indices where removedIds.contains(current.marks[index].id) {
            if current.marks[index].source == .claude { current.marks[index].hidden = true }
        }
        current.marks.removeAll { $0.source == .manual && removedIds.contains($0.id) }
        current.rewrite = newItems
        current.rewriteEdited = true
        let edit = ManualMarkEdit(blockId: blockId, beforeBlock: before, afterBlock: current, termId: nil, beforeTerm: nil, afterTerm: nil)
        await apply(edit, actionName: "edit text")
    }

    /// SPEC §5.6 "Restore Claude's Version": `rewrite` goes back to
    /// `claudeRewrite` and the "edited" label disappears. CLAUDE's marks/links
    /// return exactly as Claude produced them (`claudeMarks`/`claudeLinks`, the
    /// snapshot taken by `AnalysisPersistence.save`), not just the text: a mark
    /// hidden or changed in type during "Edit text" (§5.6) or with
    /// "Change"/"Remove" (§5.7) becomes visible again with its original type.
    /// The block's MANUAL marks are not touched (SPEC does not ask for it: they
    /// are the user's content, not Claude's; a manual mark that was really
    /// deleted stays deleted, by construction unrecoverable). Manual links are
    /// recomputed on the updated marks (`recomputeLinks`, the same pattern as
    /// `addManualMark`/`changeMarkType`/`removeMark`). If the block was
    /// analyzed BEFORE this snapshot existed (`claudeMarks`/`claudeLinks` still
    /// `nil`), the marks stay unchanged as in the previous behavior: only a new
    /// analysis/regeneration save creates the snapshot.
    func restoreClaudeVersion(blockId: String) async {
        guard let context, let block = context.blocks.first(where: { $0.id == blockId }),
              var current = context.analysis.blocks[blockId] else { return }
        current.rewrite = current.claudeRewrite
        current.rewriteEdited = false
        if let claudeMarks = current.claudeMarks {
            current.marks = current.marks.filter { $0.source == .manual } + claudeMarks
        }
        if let claudeLinks = current.claudeLinks {
            current.links = claudeLinks
        }
        recomputeLinks(&current, block: block)
        await applyChange(blockId: blockId, blockAnalysis: current, termId: nil, term: nil)
    }

    /// Updates the LOCAL state (queue context + rectangle cache + notification
    /// to overlay/panel/map) BEFORE talking to the Store, not after. This
    /// function used to do `await queue.store.updateAnalysis(...)` as its first
    /// step: a MainActor→actor→MainActor round trip on every single mark
    /// added/changed/removed BEFORE the overlay/panel noticed the change. An
    /// `async` function runs synchronously up to the first REAL suspension: by
    /// moving the local update before that `await`, the caller (`Task { await
    /// ... }` in the mini selection bar, or a direct `await` in tests) sees the
    /// overlay/panel already updated at the same instant, while the Store round
    /// trip is still `await`ed all the way through (not a detached `Task`), so
    /// a later `flush()`/read always sees the most recent state (no race
    /// between this function and its caller). `blockAnalysis`/`term` `nil` =
    /// remove the entry (used by the undo of an addition that had created it
    /// from scratch).
    private func applyChange(blockId: String, blockAnalysis: BlockAnalysis?, termId: String?, term: TermRecord?) async {
        applyLocalChange(
            blockId: blockId, blockAnalysis: blockAnalysis,
            termId: termId, term: term,
            resetManualMarkUndo: true
        )
        guard let fingerprint = context?.fingerprint else { return }
        await enqueuePersistence(
            fingerprint: fingerprint, blockId: blockId,
            blockAnalysis: blockAnalysis, termId: termId, term: term
        ).value
    }

    /// Like `applyChange`, but for `performManualMarkUndo`/`performManualMarkRedo`
    /// (called from a SYNCHRONOUS `UndoManager.registerUndo` handler, which
    /// cannot `await`): the local update is still immediate, and the Store
    /// round trip starts in a detached `Task` instead of being awaited, exactly
    /// like `AnnotationController.persist()` for the same reason.
    private func applyChangeFireAndForget(blockId: String, blockAnalysis: BlockAnalysis?, termId: String?, term: TermRecord?) {
        applyLocalChange(
            blockId: blockId, blockAnalysis: blockAnalysis,
            termId: termId, term: term,
            resetManualMarkUndo: false
        )
        guard let fingerprint = context?.fingerprint else { return }
        enqueuePersistence(
            fingerprint: fingerprint, blockId: blockId,
            blockAnalysis: blockAnalysis, termId: termId, term: term
        )
    }

    private func applyLocalChange(
        blockId: String, blockAnalysis: BlockAnalysis?, termId: String?, term: TermRecord?,
        resetManualMarkUndo: Bool
    ) {
        queue.applyLocalContextUndo(blockId: blockId, blockAnalysis: blockAnalysis, termId: termId, term: term)
        // The same notification path as a completed analysis: it updates
        // overlay, panel and map revision also for additions, changes,
        // removals, edits, local restores and undo/redo, BEFORE talking to the
        // Store (see above).
        analysisDataDidChange(blockId: blockId, resetManualMarkUndo: resetManualMarkUndo)
    }

    /// Serializes all the mark writes, including those launched from
    /// synchronous `UndoManager` handlers, keeping on disk the same order the
    /// user already saw in the UI.
    @discardableResult
    private func enqueuePersistence(
        fingerprint: String, blockId: String, blockAnalysis: BlockAnalysis?,
        termId: String?, term: TermRecord?
    ) -> Task<Void, Never> {
        let predecessor = manualMarksPersistenceTask
        let store = queue.store
        let task = Task {
            await predecessor?.value
            await store.updateAnalysis(fingerprint: fingerprint) { record in
                if let termId {
                    if let term { record.terms[termId] = term } else { record.terms.removeValue(forKey: termId) }
                }
                if let blockAnalysis { record.blocks[blockId] = blockAnalysis } else { record.blocks.removeValue(forKey: blockId) }
            }
        }
        manualMarksPersistenceTask = task
        return task
    }
}
