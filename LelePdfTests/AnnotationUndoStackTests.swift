import Testing
@testable import LelePdf

/// Pure `AnnotationUndoStack` (SPEC §5.13 "Undo/Redo", "undo/redo stack
/// behaviour on the model controller").
///
/// Note: every `undo`/`redo` is assigned to a `let` BEFORE `#expect(...)`
/// instead of being called inside the macro — `#expect` cannot expand a
/// mutating call on a local `var` when it also takes an `inout` argument in
/// the same expression ("cannot use mutating member on immutable value:
/// '$0' is immutable", a macro limitation).
@Suite("AnnotationUndoStack")
struct AnnotationUndoStackTests {
    private func annotation(id: String, page: Int = 0) -> Annotation {
        Annotation(id: id, page: page, kind: .rectangle, color: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1), rect: AnnotationRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test("undoing a creation removes it, redo puts it back")
    func undoRedoCreate() {
        var stack = AnnotationUndoStack()
        var items: [Annotation] = []
        let created = annotation(id: "a1")
        items.append(created)
        stack.record(AnnotationEdit(annotationId: "a1", before: nil, after: created))

        let undone = stack.undo(applyingTo: &items)
        #expect(undone)
        #expect(items.isEmpty)
        let redone = stack.redo(applyingTo: &items)
        #expect(redone)
        #expect(items == [created])
    }

    @Test("undoing a deletion puts it back, redo removes it again")
    func undoRedoDelete() {
        var stack = AnnotationUndoStack()
        let original = annotation(id: "a1")
        var items = [original]
        items.removeAll()
        stack.record(AnnotationEdit(annotationId: "a1", before: original, after: nil))

        let undone = stack.undo(applyingTo: &items)
        #expect(undone)
        #expect(items == [original])
        let redone = stack.redo(applyingTo: &items)
        #expect(redone)
        #expect(items.isEmpty)
    }

    @Test("undoing a move/color change goes back to the previous version")
    func undoRedoUpdate() {
        var stack = AnnotationUndoStack()
        let before = annotation(id: "a1")
        var after = before
        after.rect = AnnotationRect(x: 20, y: 20, width: 10, height: 10)
        var items = [after]
        stack.record(AnnotationEdit(annotationId: "a1", before: before, after: after))

        let undone = stack.undo(applyingTo: &items)
        #expect(undone)
        #expect(items == [before])
        let redone = stack.redo(applyingTo: &items)
        #expect(redone)
        #expect(items == [after])
    }

    @Test("a new edit after an undo clears the redo stack")
    func newEditAfterUndoClearsRedo() {
        var stack = AnnotationUndoStack()
        var items = [annotation(id: "a1")]
        stack.record(AnnotationEdit(annotationId: "a1", before: nil, after: items[0]))
        _ = stack.undo(applyingTo: &items)
        #expect(stack.canRedo)

        let second = annotation(id: "a2")
        items.append(second)
        stack.record(AnnotationEdit(annotationId: "a2", before: nil, after: second))
        #expect(!stack.canRedo)
    }

    @Test("undo/redo on an empty stack does nothing and returns false")
    func emptyStackNoOps() {
        var stack = AnnotationUndoStack()
        var items: [Annotation] = []
        let undone = stack.undo(applyingTo: &items)
        #expect(!undone)
        let redone = stack.redo(applyingTo: &items)
        #expect(!redone)
    }

    @Test("several edits undo in reverse order")
    func multipleEditsUndoInReverseOrder() {
        var stack = AnnotationUndoStack()
        var items: [Annotation] = []
        let a1 = annotation(id: "a1")
        let a2 = annotation(id: "a2")
        items.append(a1)
        stack.record(AnnotationEdit(annotationId: "a1", before: nil, after: a1))
        items.append(a2)
        stack.record(AnnotationEdit(annotationId: "a2", before: nil, after: a2))

        let firstUndo = stack.undo(applyingTo: &items)
        #expect(firstUndo)
        #expect(items == [a1])
        let secondUndo = stack.undo(applyingTo: &items)
        #expect(secondUndo)
        #expect(items.isEmpty)
        let thirdUndo = stack.undo(applyingTo: &items)
        #expect(!thirdUndo)
    }
}
