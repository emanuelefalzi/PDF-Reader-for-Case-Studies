import Testing
import Foundation
import CoreGraphics
@testable import LelePdf

/// `AnnotationController` (SPEC §5.13: "undo/redo stack behaviour on the
/// model controller (create, move, recolor, delete → undo each)"; "eraser
/// removes touched strokes only"). Store on a temporary folder, never
/// `~/Documents` (privacy-protected folder).
@Suite("AnnotationController", .serialized)
@MainActor
struct AnnotationControllerTests {
    private func makeController() async -> AnnotationController {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfAnnotationControllerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-annotations"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        let controller = AnnotationController(store: store)
        controller.load(fingerprint: fingerprint, items: [])
        return controller
    }

    @Test("creating an annotation adds it; undo removes it, redo puts it back")
    func createUndoRedo() async {
        let controller = await makeController()
        controller.createShape(kind: .rectangle, page: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(controller.annotations.count == 1)
        let id = controller.annotations[0].id

        #expect(controller.performUndo())
        #expect(controller.annotations.isEmpty)
        #expect(controller.performRedo())
        #expect(controller.annotations.map(\.id) == [id])
    }

    @Test("moving (updating the rect) is undoable")
    func moveUndoRedo() async {
        let controller = await makeController()
        controller.createShape(kind: .rectangle, page: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        let id = controller.annotations[0].id
        let originalRect = controller.annotations[0].rect

        controller.update(id: id, actionName: "Sposta") { $0.rect = AnnotationRect(x: 100, y: 100, width: 50, height: 50) }
        #expect(controller.annotations[0].rect != originalRect)

        #expect(controller.performUndo())
        #expect(controller.annotations[0].rect == originalRect)
        #expect(controller.performRedo())
        #expect(controller.annotations[0].rect == AnnotationRect(x: 100, y: 100, width: 50, height: 50))
    }

    @Test("changing the color is undoable")
    func recolorUndoRedo() async {
        let controller = await makeController()
        controller.createShape(kind: .ellipse, page: 0, rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        let id = controller.annotations[0].id
        let originalColor = controller.annotations[0].color

        let newColor = AnnotationColor(red: 0, green: 1, blue: 0, alpha: 1)
        controller.update(id: id, actionName: "Colore") { $0.color = newColor }
        #expect(controller.annotations[0].color == newColor)

        #expect(controller.performUndo())
        #expect(controller.annotations[0].color == originalColor)
        #expect(controller.performRedo())
        #expect(controller.annotations[0].color == newColor)
    }

    @Test("deleting is undoable: undo puts it back, redo removes it again")
    func deleteUndoRedo() async {
        let controller = await makeController()
        controller.createShape(kind: .star, page: 0, rect: CGRect(x: 0, y: 0, width: 30, height: 30))
        let id = controller.annotations[0].id
        let created = controller.annotations[0]

        controller.delete(id: id)
        #expect(controller.annotations.isEmpty)
        #expect(controller.performUndo())
        #expect(controller.annotations == [created])
        #expect(controller.performRedo())
        #expect(controller.annotations.isEmpty)
    }

    @Test("an update that changes nothing does not add an extra undo entry")
    func noOpUpdateDoesNotRecord() async {
        let controller = await makeController()
        controller.createShape(kind: .rectangle, page: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        let id = controller.annotations[0].id
        let rect = controller.annotations[0].rect
        controller.update(id: id) { $0.rect = rect } // same geometry, no real change

        // If the no-op update had recorded an entry, it would take TWO undos
        // to get back to "no annotations"; here a single one is enough (the
        // creation's).
        #expect(controller.performUndo())
        #expect(controller.annotations.isEmpty)
        #expect(!controller.performUndo())
    }

    @Test("the eraser removes ONLY the touched strokes, not the others")
    func eraserRemovesOnlyTouchedAnnotations() async {
        let controller = await makeController()
        controller.createInk(page: 0, rawPoints: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0)])
        controller.createInk(page: 0, rawPoints: [CGPoint(x: 0, y: 100), CGPoint(x: 50, y: 100)])
        #expect(controller.annotations.count == 2)
        let touchedId = controller.annotations[0].id
        let untouchedId = controller.annotations[1].id

        controller.eraseAnnotations(ids: [touchedId])
        #expect(controller.annotations.map(\.id) == [untouchedId])
    }

    @Test("selectAnnotation finds the touched annotation on the right page")
    func selectAnnotationFindsHit() async {
        let controller = await makeController()
        controller.createShape(kind: .rectangle, page: 2, rect: CGRect(x: 0, y: 0, width: 40, height: 40))
        let id = controller.annotations[0].id
        #expect(controller.selectAnnotation(at: CGPoint(x: 0, y: 20), page: 2))
        #expect(controller.selectedId == id)
        #expect(!controller.selectAnnotation(at: CGPoint(x: 500, y: 500), page: 2))
        #expect(controller.selectedId == nil)
    }
}
