import Testing
import Foundation
import CoreGraphics
@preconcurrency import PDFKit
@testable import LelePdf

/// Additional tests from the M7b cross-review (SPEC §5.13): they cover two
/// real bugs found and fixed during the review (the text of highlights was
/// never saved; erasing several strokes was not grouped into a single
/// undo/redo entry), which the M7b suite did not catch because those tests
/// built `Annotation` by hand instead of going through the real creation path
/// (`AnnotationTextMarkupCreator`/`eraseAnnotations`).
extension HeavyTestSuites {
@Suite("M7b cross-review", .serialized)
@MainActor
struct ReviewM7bTests {
    private func makeController(pageCount: Int = 5) async -> AnnotationController {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfReviewM7bTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-review-m7b"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: pageCount)
        let controller = AnnotationController(store: store)
        controller.load(fingerprint: fingerprint, items: [])
        return controller
    }

    // MARK: - Bug 1: the highlighted/underlined/struck-through text was not saved

    @Test("highlighting a real selection saves the selected text on the annotation")
    func textMarkupCapturesSelectedText() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found in \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        guard let page = document.page(at: 0), let string = page.string, !string.isEmpty else {
            print("SKIP: page 0 of the Merck PDF has no usable text")
            return
        }
        let range = NSRange(location: 0, length: min(30, (string as NSString).length))
        guard let selection = page.selection(for: range) else {
            print("SKIP: no selection obtainable for the test range")
            return
        }
        let expectedFirstWord = try #require(selection.string?.split(separator: " ").first.map(String.init))

        let controller = await makeController()
        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: selection, document: document, controller: controller)

        let annotation = try #require(controller.annotations.first)
        let text = try #require(annotation.text, "the highlighted text must be saved (SPEC §5.13, Markdown export)")
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(text.contains(expectedFirstWord))
    }

    @Test("highlighting via the selection mini bar (M7) also saves the text there")
    func textMarkupFromMiniBarPathCapturesText() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found in \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        guard let page = document.page(at: 0), let string = page.string, !string.isEmpty else {
            print("SKIP: page 0 of the Merck PDF has no usable text")
            return
        }
        let range = NSRange(location: 0, length: min(20, (string as NSString).length))
        guard let selection = page.selection(for: range) else {
            print("SKIP: no selection obtainable for the test range")
            return
        }

        let controller = await makeController()
        // The same call used by `MarksOverlaySelectionBar.annotationTextItems`
        // (SPEC §5.13 deliverable 3, "Text tools also appear in the M7
        // selection mini bar"): an explicit color, as from the bar.
        AnnotationTextMarkupCreator.apply(
            kind: .underline, selection: selection, document: document, controller: controller,
            color: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let annotation = try #require(controller.annotations.first)
        #expect(annotation.text?.isEmpty == false)
    }

    @Test("a multi-page selection saves the text of each page separately")
    func multiPageTextMarkupCapturesPerPageText() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found in \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        guard document.pageCount >= 2,
              let page0 = document.page(at: 0), let page1 = document.page(at: 1),
              let string0 = page0.string, let string1 = page1.string, !string0.isEmpty, !string1.isEmpty,
              let selection0 = page0.selection(for: NSRange(location: 0, length: min(15, (string0 as NSString).length))),
              let selection1 = page1.selection(for: NSRange(location: 0, length: min(15, (string1 as NSString).length))) else {
            print("SKIP: the first two pages of the Merck PDF have no usable text")
            return
        }
        selection0.add(selection1)

        let controller = await makeController()
        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: selection0, document: document, controller: controller)

        #expect(controller.annotations.count == 2)
        for annotation in controller.annotations {
            let text = try #require(annotation.text)
            #expect(!text.isEmpty)
        }
        // The two annotations must not share the same whole selection text
        // (fixed bug: previously nothing was saved at all, and a naive fix
        // could instead have repeated the entire `selection.string` on both
        // pages).
        let texts = Set(controller.annotations.compactMap(\.text))
        #expect(texts.count == 2)
    }

    @Test("the saved text reaches the Markdown export for an annotation created through the real path")
    func exportedMarkdownContainsRealHighlightedText() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found in \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        guard let page = document.page(at: 0), let string = page.string, !string.isEmpty,
              let selection = page.selection(for: NSRange(location: 0, length: min(25, (string as NSString).length))) else {
            print("SKIP: page 0 of the Merck PDF has no usable text")
            return
        }

        let controller = await makeController()
        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: selection, document: document, controller: controller)
        let annotation = try #require(controller.annotations.first)
        let text = try #require(annotation.text)

        let sections = AnnotationMarkdown.sectionsByPage(AnnotationsRecord(items: [annotation]), headingPrefix: "###")
        let rendered = try #require(sections[annotation.page])
        #expect(rendered.contains(text))
    }

    // MARK: - Bug 2: erasing several strokes was not a single undo/redo entry

    @Test("erasing several strokes in a single gesture is ONE undo/redo entry")
    func eraseMultipleStrokesIsOneUndoStep() async {
        let controller = await makeController()
        controller.createInk(page: 0, rawPoints: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0)])
        controller.createInk(page: 0, rawPoints: [CGPoint(x: 0, y: 100), CGPoint(x: 50, y: 100)])
        controller.createInk(page: 0, rawPoints: [CGPoint(x: 0, y: 200), CGPoint(x: 50, y: 200)])
        #expect(controller.annotations.count == 3)
        let ids = controller.annotations.map(\.id)

        // A single eraser gesture touches the first two strokes (like
        // `AnnotationOverlayView`, which accumulates the touched ids during a
        // drag and calls `eraseAnnotations` once on `mouseUp`).
        controller.eraseAnnotations(ids: [ids[0], ids[1]])
        #expect(controller.annotations.map(\.id) == [ids[2]])

        // A SINGLE `performUndo()` must restore BOTH erased strokes (fixed
        // bug: previously each stroke was a separate entry, so two ⌘Z were
        // needed to restore both).
        #expect(controller.performUndo())
        #expect(Set(controller.annotations.map(\.id)) == Set(ids))

        // A second undo must not touch anything else (there was only one
        // group): it undoes the creation of the third stroke, not a fourth
        // eraser step that no longer exists.
        #expect(controller.performUndo())
        #expect(controller.annotations.map(\.id) == [ids[0], ids[1]])

        // Symmetric redo: a single `performRedo()` puts back the third stroke,
        // a second `performRedo()` erases both of the first two together.
        #expect(controller.performRedo())
        #expect(Set(controller.annotations.map(\.id)) == Set(ids))
        #expect(controller.performRedo())
        #expect(controller.annotations.map(\.id) == [ids[2]])
    }

    @Test("AnnotationUndoStack.recordGroup: a single undo/redo for the whole group")
    func undoStackGroupedEditsUndoRedoTogether() {
        var stack = AnnotationUndoStack()
        var items: [Annotation] = []
        let a = Annotation(id: "a1", page: 0, kind: .ink, color: AnnotationColor(red: 0, green: 0, blue: 0, alpha: 1), rect: AnnotationRect(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let b = Annotation(id: "a2", page: 0, kind: .ink, color: AnnotationColor(red: 0, green: 0, blue: 0, alpha: 1), rect: AnnotationRect(CGRect(x: 20, y: 20, width: 10, height: 10)))
        items = [a, b]

        stack.recordGroup([
            AnnotationEdit(annotationId: "a1", before: a, after: nil),
            AnnotationEdit(annotationId: "a2", before: b, after: nil),
        ])
        // Manually apply the group's "after" state (as
        // `AnnotationController.applyGroup` would), then verify that a single
        // `undo` restores it entirely.
        items.removeAll()
        #expect(stack.canUndo)
        let undone = stack.undo(applyingTo: &items)
        #expect(undone)
        #expect(Set(items.map(\.id)) == ["a1", "a2"])
        #expect(!stack.canUndo)
        #expect(stack.canRedo)

        let redone = stack.redo(applyingTo: &items)
        #expect(redone)
        #expect(items.isEmpty)
    }
}
}
