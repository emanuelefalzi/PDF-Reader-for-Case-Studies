import Foundation

/// Undo/redo of manual marks (SPEC §5.7): same pattern as
/// `AnnotationEdit`/`AnnotationUndoStack`. A pure stack here, independent of
/// `UndoManager` (AppKit) and testable on its own; the bridge to the window's
/// real `UndoManager` lives in `AnalysisController` (`undoManager`), set to
/// the SAME `UndoManager` used by `AnnotationController` so that ⌘Z/⇧⌘Z
/// interleave the two stacks in the real order of actions.
///
/// Unlike annotations (a single object per id), a "unit" here is the whole
/// `BlockAnalysis` of the touched block: simpler and more robust than a
/// per-mark diff (an addition can create the block's entry from scratch if it
/// was not analyzed yet: `beforeBlock == nil` in that case, and undoing must
/// REMOVE the entry, not leave it empty) and it also covers, in one go, the
/// derived links recomputed together with the marks (`ManualLinkDerivation`).
/// `termId`/`beforeTerm`/`afterTerm` cover only the "add" case when it
/// creates a new term.
struct ManualMarkEdit: Sendable, Equatable {
    var blockId: String
    var beforeBlock: BlockAnalysis?
    var afterBlock: BlockAnalysis?
    var termId: String?
    var beforeTerm: TermRecord?
    var afterTerm: TermRecord?
}

struct ManualMarksUndoStack {
    private(set) var undoStack: [ManualMarkEdit] = []
    private(set) var redoStack: [ManualMarkEdit] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records an already-applied change: a new change after an undo makes
    /// the earlier redos unreachable (as in any editor with an `UndoManager`,
    /// the same behavior as `AnnotationUndoStack`).
    mutating func record(_ edit: ManualMarkEdit) {
        undoStack.append(edit)
        redoStack.removeAll()
    }

    /// Moves the last change from the undo stack to the redo stack and
    /// returns it, `nil` if there is nothing to undo.
    mutating func popUndo() -> ManualMarkEdit? {
        guard let edit = undoStack.popLast() else { return nil }
        redoStack.append(edit)
        return edit
    }

    /// Like `popUndo`, but in the opposite direction.
    mutating func popRedo() -> ManualMarkEdit? {
        guard let edit = redoStack.popLast() else { return nil }
        undoStack.append(edit)
        return edit
    }

    mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
