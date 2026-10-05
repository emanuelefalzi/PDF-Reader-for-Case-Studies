import AppKit
import Foundation
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// F10 (heading shortcuts): ⌘⌥1…4 (`DocumentModel.applyTocLevelShortcut`) on a
/// REAL selection of a real `PDFView`. Same pattern as
/// `TocHighlightAfterNavigationTests` (`ScrollSyncCurrentPageTests.makeModel`):
/// a real `PDFReaderBridge`, so `readerBridge?.currentSelection` reads the
/// `PDFView`'s real selection, not a synthetic double.
extension HeavyTestSuites {
@MainActor
@Suite("F10: ⌘⌥1…4 on a real PDF selection", .serialized)
struct ManualTocShortcutRealSelectionTests {
    private func makeModel() throws -> (model: DocumentModel, pdfView: PDFView, window: NSWindow) {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Ciao mondo, prova LelePdf.", fileName: "toc-shortcut-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "toc-shortcut-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1

        let window = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pdfView
        window.layoutIfNeeded()

        model.readerBridge = PDFReaderBridge(pdfView: pdfView)
        return (model, pdfView, window)
    }

    /// Selects a REAL character range on the first page
    /// (`page.selection(for:)`, same technique as
    /// `AnnotationRealEventHarness.textDragRange`) and sets it as the
    /// `PDFView`'s current selection, exactly what the user would have after a
    /// real drag.
    private func select(_ range: NSRange, in model: DocumentModel, pdfView: PDFView) throws {
        let page = try #require(model.pdfDocument.page(at: 0))
        let selection = try #require(page.selection(for: range))
        pdfView.setCurrentSelection(selection, animate: false)
    }

    @Test("⌘⌥1 on selected text: creates a manual T1 entry with the right page/pageY")
    func createsManualEntry() throws {
        let (model, pdfView, window) = try makeModel()
        defer { closeTestWindow(window) }
        try select(NSRange(location: 0, length: 4), in: model, pdfView: pdfView) // "Ciao"

        model.applyTocLevelShortcut(level: 1)

        let entry = try #require(model.tocEntries.first)
        #expect(entry.title == "Ciao")
        #expect(entry.level == 1)
        #expect(entry.page == 0)
        #expect(entry.pageY != nil)
        #expect(entry.isManual)
    }

    @Test("⌘⌥N on a selection that is already an entry: changes level, does not duplicate")
    func changesLevelOfExistingEntry() throws {
        let (model, pdfView, window) = try makeModel()
        defer { closeTestWindow(window) }
        try select(NSRange(location: 0, length: 4), in: model, pdfView: pdfView)
        model.applyTocLevelShortcut(level: 1)
        #expect(model.tocEntries.count == 1)

        // Reselects the SAME text (same page, same clean title) and asks for a
        // different level: it must change the existing entry.
        try select(NSRange(location: 0, length: 4), in: model, pdfView: pdfView)
        model.applyTocLevelShortcut(level: 3)

        #expect(model.tocEntries.count == 1)
        #expect(model.tocEntries[0].level == 3)
    }

    @Test("⌘⌥N without a selection: no effect")
    func noSelectionIsNoOp() throws {
        let (model, _, window) = try makeModel()
        defer { closeTestWindow(window) }
        model.applyTocLevelShortcut(level: 2)
        #expect(model.tocEntries.isEmpty)
    }

    @Test("undoable: performTocUndo removes the entry just created, performTocRedo restores it")
    func undoRedo() throws {
        let (model, pdfView, window) = try makeModel()
        defer { closeTestWindow(window) }
        try select(NSRange(location: 0, length: 4), in: model, pdfView: pdfView)
        model.applyTocLevelShortcut(level: 1)
        #expect(model.tocEntries.count == 1)
        #expect(model.manualTocUndoStack.canUndo)

        #expect(model.performTocUndo())
        #expect(model.tocEntries.isEmpty)

        #expect(model.performTocRedo())
        #expect(model.tocEntries.count == 1)
        #expect(model.tocEntries[0].level == 1)
    }

    @Test("real ⌘Z/⇧⌘Z (system UndoManager, like marks/annotations): same stack, same order")
    func realSystemUndoManager() throws {
        let (model, pdfView, window) = try makeModel()
        defer { closeTestWindow(window) }
        // Same pattern as `MarksOverlayView.viewDidMoveToWindow`.
        model.analysisController.undoManager = window.undoManager
        try select(NSRange(location: 0, length: 4), in: model, pdfView: pdfView)
        model.applyTocLevelShortcut(level: 1)
        #expect(model.tocEntries.count == 1)

        window.undoManager?.undo()
        #expect(model.tocEntries.isEmpty)

        window.undoManager?.redo()
        #expect(model.tocEntries.count == 1)
    }
}
}
