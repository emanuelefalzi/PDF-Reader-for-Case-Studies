import Foundation
import Observation

/// Per-window annotation state (SPEC §5.13), owned by `DocumentModel` like
/// `analysisController`/`syncCoordinator`. It does not depend on PDFKit:
/// native rendering lives in `AnnotationRenderer` (MainActor,
/// `@preconcurrency import PDFKit`), mouse interaction in
/// `AnnotationOverlayView`. Pure undo/redo in `AnnotationUndoStack`, bridge
/// to the window's real `UndoManager` below.
@MainActor
@Observable
final class AnnotationController {
    private let store: DocumentStore

    /// Not `private(set)`: mutated directly by
    /// `AnnotationController+Drag.swift` (`liveMove`/`liveResize`, live
    /// mutation without undo/redo on every tick): same type, separate file
    /// to keep files small.
    var annotations: [Annotation] = []
    private var fingerprint: String?
    private var undoStack = AnnotationUndoStack()

    /// Active tool in the Annotate bar (SPEC "Annotate bar"): defaults to
    /// `.select` until the bar has ever been opened.
    var tool: AnnotationTool = .select
    var barVisible = false {
        didSet { if !barVisible { selectedId = nil; tool = .select } }
    }
    var selectedId: String?
    /// Snapshot taken by `beginMove()` (`AnnotationController+Drag.swift`),
    /// compared with the current state at `commitDrag()` to record ONE
    /// single undo/redo entry for the whole drag.
    var dragSnapshot: Annotation?

    /// Current color/width for the active tool (SPEC "the last one used for
    /// each tool is remembered"): read/written from `UserDefaults` through
    /// `AnnotationToolMemory`, cached here only to avoid rereading them on
    /// every gesture.
    var currentColor: AnnotationPaletteColor = .yellow {
        didSet { AnnotationToolMemory.setLastColor(currentColor, for: tool) }
    }
    var currentWidth: AnnotationLineWidth = .medium {
        didSet { AnnotationToolMemory.setLastWidth(currentWidth, for: tool) }
    }

    /// Called by `AnnotationRenderer` after every mutation, to reflect the
    /// annotations onto the in-memory `PDFDocument` (no direct coupling to
    /// PDFKit here, SPEC §6.3 "the Store never touches PDFKit": this is not
    /// the Store but follows the same separation rule).
    var onAnnotationsChanged: (@MainActor () -> Void)?

    /// Notifies a user edit already handed to the Store. Separate from
    /// `onAnnotationsChanged` (used by the renderer and replaced by the view)
    /// to drive the optional automatic saving into the PDF.
    var onMutationCommitted: (@MainActor () -> Void)?

    /// Bridge to the window's `UndoManager` (SPEC "use the window's
    /// UndoManager"): assigned by `AnnotationOverlayView` when it enters a
    /// window's hierarchy.
    weak var undoManager: UndoManager?

    var selected: Annotation? {
        guard let selectedId else { return nil }
        return annotations.first { $0.id == selectedId }
    }

    /// Pages with at least one annotation (SPEC §5.13 "pen icon on the
    /// thumbnails of pages with annotations").
    var annotatedPages: Set<Int> { Set(annotations.map(\.page)) }

    init(store: DocumentStore = AppStore.shared) {
        self.store = store
        tool = .select
        loadToolMemory()
    }

    private func loadToolMemory() {
        currentColor = AnnotationToolMemory.lastColor(for: tool)
        currentWidth = AnnotationToolMemory.lastWidth(for: tool)
    }

    /// Changes tool (Annotate bar): reloads the remembered color/width for
    /// the NEW tool (SPEC "the last one used for each tool").
    func selectTool(_ newTool: AnnotationTool) {
        tool = newTool
        selectedId = nil
        loadToolMemory()
    }

    /// To be called when the document opens (SPEC "reopening: they reappear
    /// ... within 1 s") and after every Store reload.
    func load(fingerprint: String, items: [Annotation]) {
        self.fingerprint = fingerprint
        annotations = items
        undoStack.removeAll()
        selectedId = nil
        onAnnotationsChanged?()
    }

    // MARK: - Persistence (SPEC §8 `annotazioni.json`)

    /// Not `private`: also called by `AnnotationController+Drag.swift`
    /// after `commitDrag` (same type, separate file to keep files small).
    func persist() {
        guard let fingerprint else { return }
        let snapshot = annotations
        Task { await self.store.updateAnnotations(fingerprint: fingerprint) { record in record.items = snapshot } }
        onMutationCommitted?()
    }

    // MARK: - CRUD with undo/redo (SPEC "Undo/Redo for all operations")

    /// Applies an already-computed edit (creation/move/...), records it on
    /// the pure stack (`AnnotationUndoStack`, testable on its own) and arms
    /// ONE undo entry on the system `UndoManager`, so ⌘Z/⇧⌘Z of the Edit
    /// menu work without this controller being an `NSObject`: the classic
    /// scheme "every undo arms the matching redo and vice versa"
    /// (`armSystemUndo`/`armSystemRedo`).
    func apply(_ edit: AnnotationEdit, actionName: String) {
        applyToState(edit.after, id: edit.annotationId)
        undoStack.record(edit)
        armSystemUndo(actionName: actionName)
    }

    /// Like `apply`, but for several independent edits of ONE gesture
    /// (eraser over several strokes in a drag): a single undo/redo for the
    /// whole group, not one per touched annotation (fixed bug:
    /// `eraseAnnotations` used to call `apply` once per id).
    func applyGroup(_ edits: [AnnotationEdit], actionName: String) {
        guard !edits.isEmpty else { return }
        for edit in edits { applyToState(edit.after, id: edit.annotationId) }
        undoStack.recordGroup(edits)
        armSystemUndo(actionName: actionName)
    }

    private func applyToState(_ value: Annotation?, id: String) {
        if let value {
            if let index = annotations.firstIndex(where: { $0.id == id }) {
                annotations[index] = value
            } else {
                annotations.append(value)
            }
        } else {
            annotations.removeAll { $0.id == id }
            if selectedId == id { selectedId = nil }
        }
        persist()
        onAnnotationsChanged?()
    }

    private func armSystemUndo(actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.performUndo()
            target.armSystemRedo(actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private func armSystemRedo(actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.performRedo()
            target.armSystemUndo(actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    /// Undoes the last edit on the pure stack (called by the system
    /// `UndoManager`, but also testable on its own without AppKit).
    @discardableResult
    func performUndo() -> Bool {
        guard undoStack.undo(applyingTo: &annotations) else { return false }
        if let selectedId, !annotations.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
        persist()
        onAnnotationsChanged?()
        return true
    }

    @discardableResult
    func performRedo() -> Bool {
        guard undoStack.redo(applyingTo: &annotations) else { return false }
        persist()
        onAnnotationsChanged?()
        return true
    }

    /// Creation (SPEC "free tools on the page ... create an annotation"):
    /// no `before`.
    func create(_ annotation: Annotation, actionName: String = "Create Annotation") {
        apply(AnnotationEdit(annotationId: annotation.id, before: nil, after: annotation), actionName: actionName)
    }

    /// Deletion (SPEC "⌫ deletes"): no `after`.
    func delete(id: String, actionName: String = "Delete Annotation") {
        guard let current = annotations.first(where: { $0.id == id }) else { return }
        apply(AnnotationEdit(annotationId: id, before: current, after: nil), actionName: actionName)
    }

    func deleteSelected() {
        guard let selectedId else { return }
        delete(id: selectedId)
    }

    /// Generic update (move, resize, color change): `mutate` receives the
    /// current copy, `updatedAt` is updated automatically.
    func update(id: String, actionName: String = "Edit Annotation", _ mutate: (inout Annotation) -> Void) {
        guard let before = annotations.first(where: { $0.id == id }) else { return }
        var after = before
        mutate(&after)
        // The comparison must be made BEFORE touching `updatedAt`: always
        // stamping it would make `after != before` true even for a mutation
        // that changes nothing (two `Date()` values are never equal).
        guard after != before else { return }
        after.updatedAt = Date()
        apply(AnnotationEdit(annotationId: id, before: before, after: after), actionName: actionName)
    }

    func nextId() -> String { AnnotationIdentifiers.nextId(in: annotations) }

    /// Records an edit ALREADY applied elsewhere to the state
    /// (`AnnotationController+Drag.swift`, `commitDrag`: `liveMove`/
    /// `liveResize` already mutated `annotations` on every tick of the drag)
    /// without applying it a second time.
    func recordAppliedEdit(_ edit: AnnotationEdit, actionName: String) {
        undoStack.record(edit)
        armSystemUndo(actionName: actionName)
    }
}
