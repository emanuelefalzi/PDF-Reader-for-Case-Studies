import Testing
import Foundation
import AppKit
@preconcurrency import PDFKit
@testable import LelePdf

/// "Delete" (X) button on a note/textbox — user-reported bug: "notes must
/// also be deletable from an x button at the top right ... like Preview",
/// visible when the note is selected or under the mouse, undoable with ⌘Z
/// like the other annotation edits.
///
/// NO real `NSWindow` here (unlike an earlier attempt): an
/// `AnnotationOverlayView` added as a real subview of a `PDFView` inside a
/// real `NSWindow` installs an `NSTrackingArea` (`updateTrackingAreas()`,
/// `+DeleteButton.swift`) that AppKit may call back asynchronously during
/// its own display cycle — a crash was found (`EXC_BAD_ACCESS`/
/// `EXC_BREAKPOINT` in `isFlipped`/`updateTrackingAreas` on a view with no
/// Swift referents left) when a window built this way is torn down by hand
/// between tests, even with an explicit teardown. `hitTest`/
/// `deleteButtonHit(atViewPoint:)` do not need a view installed in a window
/// (they work on a point already in VIEW space, with no
/// `convert(_:from: nil)` that depends on `self.window`); selection/hover
/// are set directly on the controller/overlay instead of simulating a real
/// click — the ONLY test in the whole suite that must really go through
/// `NSWindow.sendEvent` is
/// `AnnotationLiveInteractionTests.textboxToolCreatesAnnotationFromRealWindowEvent`,
/// with an even more careful teardown.
@MainActor
@Suite("Annotations: delete button (note/textbox)", .serialized)
struct AnnotationDeleteButtonTests {
    private struct Scene {
        let model: DocumentModel
        let annotationOverlay: AnnotationOverlayView
        /// Strong reference: `AnnotationController.undoManager` is `weak`.
        let undoManager: UndoManager
    }

    private func makeScene() throws -> Scene {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Pagina di prova per il bottone elimina", fileName: "delete-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "delete-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1

        // Never added to a real window hierarchy (see the comment at the top of
        // the file): `AnnotationOverlayView` still needs the real `pdfView` for
        // page↔view conversions.
        let annotationOverlay = AnnotationOverlayView(model: model, pdfView: pdfView)
        annotationOverlay.frame = pdfView.bounds

        // `viewDidMoveToWindow` (which normally wires up the window's
        // UndoManager) never fires here: it is wired by hand with a real
        // `UndoManager`, `groupsByEvent = false` so that a creation and a deletion
        // done in the same test are not coalesced into a single step (same
        // technique as `ManualMarksUndoTests`).
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.annotationController.undoManager = undoManager

        return Scene(model: model, annotationOverlay: annotationOverlay, undoManager: undoManager)
    }

    @Test("the delete button is visible for the SELECTED note, and a click (via hitTest+mouseDown) deletes it undoably")
    func deleteButtonRemovesSelectedNoteAndIsUndoable() throws {
        let scene = try makeScene()
        let controller = scene.model.annotationController
        controller.barVisible = true

        let notePoint = CGPoint(x: 60, y: 100)
        // `groupsByEvent = false` (see `makeScene`) REQUIRES an explicitly opened
        // group for every `registerUndo` — otherwise `UndoManager` raises a real
        // `NSInternalInconsistencyException` ("must begin a group before
        // registering undo"), found when it derailed the whole test run (not a
        // flaw in our code: the exception came from a test written without this
        // precaution).
        scene.undoManager.beginUndoGrouping()
        let note = controller.createNote(page: 0, at: notePoint)
        scene.undoManager.endUndoGrouping()
        controller.selectTool(.select)
        controller.selectedId = note.id // direct selection: no real click is needed for this test

        let pageButtonRect = AnnotationGeometry.deleteButtonRect(for: note.rect.cgRect)
        let buttonViewPoint = CGPoint(x: pageButtonRect.midX, y: pageButtonRect.midY)

        // `hitTest` does not need a window (point already in view space, no
        // `convert(_:from: nil)`): a real check of the routing, not just of the
        // underlying geometric calculation.
        let hit = scene.annotationOverlay.hitTest(buttonViewPoint)
        #expect(hit === scene.annotationOverlay, "the delete button of the selected note must capture the click on its own corner")

        let target = try #require(scene.annotationOverlay.deleteButtonHit(atViewPoint: buttonViewPoint))
        #expect(target.id == note.id)
        scene.undoManager.beginUndoGrouping()
        controller.delete(id: target.id, actionName: "Elimina nota") // same call as `+Mouse.swift` `mouseDown`
        scene.undoManager.endUndoGrouping()
        #expect(controller.annotations.isEmpty, "deleting via the button must remove the note")

        #expect(scene.undoManager.canUndo, "deleting from the button must arm the same UndoManager as the other edits")
        scene.undoManager.undo()
        #expect(controller.annotations.map(\.id) == [note.id], "⌘Z must bring back the note deleted via the button")

        scene.undoManager.redo()
        #expect(controller.annotations.isEmpty, "⇧⌘Z must delete it again")
    }

    @Test("the delete button is also visible just for the note UNDER THE MOUSE, no need to select it")
    func deleteButtonVisibleWhileHoveredEvenWithoutSelection() throws {
        let scene = try makeScene()
        let controller = scene.model.annotationController
        controller.barVisible = true
        controller.selectTool(.select)

        let notePoint = CGPoint(x: 60, y: 100)
        scene.undoManager.beginUndoGrouping()
        let note = controller.createNote(page: 0, at: notePoint)
        scene.undoManager.endUndoGrouping()
        #expect(controller.selectedId == nil) // created via the direct API, not selected

        let pageButtonRect = AnnotationGeometry.deleteButtonRect(for: note.rect.cgRect)
        let buttonViewPoint = CGPoint(x: pageButtonRect.midX, y: pageButtonRect.midY)

        #expect(scene.annotationOverlay.deleteButtonHit(atViewPoint: buttonViewPoint) == nil, "without selection or hover the button must not appear (SPEC 'selected OR under the mouse')")

        // Simulates the mouse passing over by setting `hoveredId` directly (a
        // non-`private` property, managed by `+DeleteButton.swift` in production
        // via `NSTrackingArea`/`mouseMoved`): avoids having to install a real
        // tracking area in this test.
        scene.annotationOverlay.hoveredId = note.id
        #expect(scene.annotationOverlay.deleteButtonHit(atViewPoint: buttonViewPoint)?.id == note.id, "under the mouse, even without selection, the button must appear")
    }

    @Test("the selected textbox also has the delete button; shapes do not")
    func onlyNoteAndTextboxGetDeleteButtonWhenSelected() throws {
        let scene = try makeScene()
        let controller = scene.model.annotationController
        controller.barVisible = true

        scene.undoManager.beginUndoGrouping()
        controller.createTextbox(page: 0, rect: CGRect(x: 40, y: 80, width: 60, height: 24), text: "Nota a margine")
        scene.undoManager.endUndoGrouping()
        let textbox = try #require(controller.annotations.first)
        controller.selectTool(.select)
        controller.selectedId = textbox.id

        let pageButtonRect = AnnotationGeometry.deleteButtonRect(for: textbox.rect.cgRect)
        let buttonViewPoint = CGPoint(x: pageButtonRect.midX, y: pageButtonRect.midY)
        #expect(scene.annotationOverlay.deleteButtonHit(atViewPoint: buttonViewPoint)?.id == textbox.id)

        scene.undoManager.beginUndoGrouping()
        controller.delete(id: textbox.id)
        scene.undoManager.endUndoGrouping()
        #expect(controller.annotations.isEmpty)

        // A selected shape (SPEC: deleted with ⌫/menu, as in Preview) must never
        // show the X button.
        scene.undoManager.beginUndoGrouping()
        controller.createShape(kind: .rectangle, page: 0, rect: CGRect(x: 40, y: 80, width: 60, height: 24))
        scene.undoManager.endUndoGrouping()
        let rectangle = try #require(controller.annotations.first)
        controller.selectedId = rectangle.id
        let rectButtonPoint = CGPoint(
            x: AnnotationGeometry.deleteButtonRect(for: rectangle.rect.cgRect).midX,
            y: AnnotationGeometry.deleteButtonRect(for: rectangle.rect.cgRect).midY
        )
        #expect(scene.annotationOverlay.deleteButtonHit(atViewPoint: rectButtonPoint) == nil)
    }
}
