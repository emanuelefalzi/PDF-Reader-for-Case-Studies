import Foundation

/// A reversible edit to a single annotation (SPEC §5.13 "Undo/Redo for all
/// annotation operations"): `before == nil` for a creation, `after == nil`
/// for a deletion, both non-nil for a move/resize/color change.
/// `annotationId` stays the same in `before`/`after` (never an id change).
struct AnnotationEdit: Sendable, Equatable {
    var annotationId: String
    var before: Annotation?
    var after: Annotation?
}

/// Pure undo/redo stack (undo/redo behavior on the model controller),
/// independent of AppKit's `UndoManager`: testable on its own over
/// `[Annotation]`. `AnnotationController` adds on top the bridge to the
/// window's real `UndoManager`, so that ⌘Z/⇧⌘Z of the system Edit menu
/// work.
struct AnnotationUndoStack {
    // Each entry in the stack is a GROUP of edits (`[AnnotationEdit]`), not
    // a single one. A gesture that touches several annotations at once
    // (eraser over several strokes in one drag, grouped into one undo step)
    // must undo/redo with ONE ⌘Z/⇧⌘Z, not one per touched annotation. An
    // earlier version of `eraseAnnotations` recorded one entry per id,
    // breaking that guarantee (found in cross review).
    private(set) var undoStack: [[AnnotationEdit]] = []
    private(set) var redoStack: [[AnnotationEdit]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records an already-applied edit as a group of ONE entry
    /// (single move/resize/creation/deletion): pushes it onto the undo stack
    /// and clears the redo stack (a new edit after an undo makes the earlier
    /// "redo"s unreachable, as in any editor built on `UndoManager`).
    mutating func record(_ edit: AnnotationEdit) {
        recordGroup([edit])
    }

    /// Records several independent edits as ONE group undone together
    /// (eraser over several strokes in a single drag): a single undo/redo
    /// for the whole group.
    mutating func recordGroup(_ edits: [AnnotationEdit]) {
        guard !edits.isEmpty else { return }
        undoStack.append(edits)
        redoStack.removeAll()
    }

    /// Applies the inverse of the last GROUP of edits to `items` and moves it
    /// onto the redo stack. `false` if there is nothing to undo. Same order
    /// (not reversed) as the group's entries: the edits in a group (e.g.
    /// eraser over several strokes) are independent of each other, so
    /// applying them in the order they were collected restores the
    /// annotations' original order in the list instead of reversing it.
    @discardableResult
    mutating func undo(applyingTo items: inout [Annotation]) -> Bool {
        guard let group = undoStack.popLast() else { return false }
        for edit in group {
            apply(before: edit.before, after: edit.after, id: edit.annotationId, to: &items, direction: .undo)
        }
        redoStack.append(group)
        return true
    }

    /// Re-applies the last undone group of edits. `false` if there is
    /// nothing to redo.
    @discardableResult
    mutating func redo(applyingTo items: inout [Annotation]) -> Bool {
        guard let group = redoStack.popLast() else { return false }
        for edit in group {
            apply(before: edit.before, after: edit.after, id: edit.annotationId, to: &items, direction: .redo)
        }
        undoStack.append(group)
        return true
    }

    private enum Direction { case undo, redo }

    private func apply(before: Annotation?, after: Annotation?, id: String, to items: inout [Annotation], direction: Direction) {
        // Undo = go back to `before`; redo = go back to `after`.
        let target = direction == .undo ? before : after
        if let target {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index] = target
            } else {
                items.append(target)
            }
        } else {
            items.removeAll { $0.id == id }
        }
    }

    mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
