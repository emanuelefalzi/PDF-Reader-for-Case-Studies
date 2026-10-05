import AppKit
import Foundation
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// F10 (heading shortcuts, multiple selection): holding ⌘ while selecting ADDS
/// the dragged piece to the previous ones, instead of replacing them.
///
/// Verification technique: `MarksOverlayView.handleMultiSelectionMouseDown/Up`
/// are called DIRECTLY with REAL `NSEvent`s (`NSEvent.mouseEvent`, real
/// modifiers/position/window, never a fake struct), the same technique already
/// used in this suite for another local monitor
/// (`PDFReaderCoordinator.applyWheelZoomStep`,
/// `PDFWheelZoomPageStabilityTests`): a local monitor
/// (`NSEvent.addLocalMonitorForEvents`) hooks into the `NSApplication.sendEvent`
/// round, not a direct `NSWindow.sendEvent`. This is the technique this suite
/// chose to stay stable (no `NSApp.sendEvent`/ordered windows, which already
/// proved unstable in this test host). The "resulting" PDFKit selection of each
/// drag (which text became `pdfView.currentSelection`) is set directly with
/// `page.selection(for:)`/`setCurrentSelection` between the mouseDown and the
/// mouseUp, the same already verified technique as
/// `ManualTocShortcutRealSelectionTests`: PDFKit itself offers no documented
/// way to reliably drive ITS native selection from a sequence of synthetic
/// `NSEvent`s outside the app's real loop (unlike annotation text/markup,
/// which resolves point→range on its own with `AnnotationTextRangeResolver`,
/// without depending on `PDFView`'s native selection). What remains under
/// test, and what THIS suite genuinely verifies, is the new F10 logic: reading
/// `event.modifierFlags` from a real `NSEvent` and combining the pieces with
/// `PDFSelection.add(_:)`.
extension HeavyTestSuites {
@MainActor
@Suite("F10: multiple selection with ⌘ from real events", .serialized)
struct MultiSelectionRealEventTests {
    private struct Scene {
        let model: DocumentModel
        let pdfView: PDFView
        let marksOverlay: MarksOverlayView
        let window: NSWindow
    }

    private func makeScene() throws -> Scene {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Ciao mondo, prova LelePdf.", fileName: "multi-select-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "multi-select-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1

        let window = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pdfView

        let marksOverlay = MarksOverlayView(model: model, pdfView: pdfView)
        marksOverlay.frame = pdfView.bounds
        pdfView.addSubview(marksOverlay)
        let bridge = PDFReaderBridge(pdfView: pdfView)
        bridge.marksOverlay = marksOverlay
        model.readerBridge = bridge

        window.layoutIfNeeded()
        window.makeKeyAndOrderFront(nil)
        for _ in 0 ..< 3 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return Scene(model: model, pdfView: pdfView, marksOverlay: marksOverlay, window: window)
    }

    private func teardown(_ scene: Scene) {
        scene.marksOverlay.stopObserving()
        scene.marksOverlay.removeFromSuperview()
        if let fileURL = scene.model.fileURL { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        closeTestWindow(scene.window)
    }

    /// A real `NSEvent`, at the position (in window coordinates) of the
    /// overlay's center. The logic under test does not look at WHERE exactly
    /// the point falls (there is no mark in these synthetic PDFs, `markAt`
    /// always returns `nil`), only that it is inside `bounds` and in the right
    /// window (`event.window === window`).
    private func mouseEvent(_ type: NSEvent.EventType, scene: Scene, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        let point = scene.marksOverlay.convert(CGPoint(x: scene.marksOverlay.bounds.midX, y: scene.marksOverlay.bounds.midY), to: nil)
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: scene.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    /// Genuinely selects `range` on the first page (`page.selection(for:)`,
    /// same technique as `ManualTocShortcutRealSelectionTests`) and sets it as
    /// the current selection: what PDFKit would have done on its own at the end
    /// of a real drag over that text.
    private func selectRange(_ range: NSRange, scene: Scene) throws {
        let page = try #require(scene.model.pdfDocument.page(at: 0))
        let selection = try #require(page.selection(for: range))
        scene.pdfView.setCurrentSelection(selection, animate: false)
    }

    /// A complete "gesture": real mouseDown/mouseUp `NSEvent`s around the REAL
    /// selection the drag would have produced (see the suite comment above on
    /// why this is not a `window.sendEvent`).
    private func gesture(_ scene: Scene, resultingSelection range: NSRange, holdingCommand: Bool) throws {
        let down = mouseEvent(.leftMouseDown, scene: scene, modifiers: holdingCommand ? [.command] : [])
        scene.marksOverlay.handleMultiSelectionMouseDown(down)
        try selectRange(range, scene: scene)
        let up = mouseEvent(.leftMouseUp, scene: scene, modifiers: holdingCommand ? [.command] : [])
        scene.marksOverlay.handleMultiSelectionMouseUp(up)
    }

    // Indices in "Ciao mondo, prova LelePdf.": Ciao=0..4, mondo=5..10, prova=12..17.
    private static let rangeCiao = NSRange(location: 0, length: 4)
    private static let rangeMondo = NSRange(location: 5, length: 5)
    private static let rangeProva = NSRange(location: 12, length: 5)

    @Test("first drag without ⌘, second with ⌘: the second piece is ADDED, it does not replace")
    func commandDragAddsToPreviousSelection() throws {
        let scene = try makeScene()
        defer { teardown(scene) }

        try gesture(scene, resultingSelection: Self.rangeCiao, holdingCommand: false)
        #expect(scene.pdfView.currentSelection?.string?.contains("Ciao") == true)
        #expect(scene.model.multiSelectionPieces.isEmpty) // no ⌘ yet: nothing accumulated.

        try gesture(scene, resultingSelection: Self.rangeMondo, holdingCommand: true)

        #expect(scene.model.multiSelectionPieces.count == 2, "expected one piece for 'Ciao' and one for 'mondo'")
        let combinedText = scene.pdfView.currentSelection?.string ?? ""
        #expect(combinedText.contains("Ciao"), "the previous piece must stay in the combined selection")
        #expect(combinedText.contains("mondo"), "the new piece dragged with ⌘ must be included")
    }

    @Test("three pieces with repeated ⌘: all three stay accumulated")
    func threeCommandDragsAccumulateThreePieces() throws {
        let scene = try makeScene()
        defer { teardown(scene) }

        try gesture(scene, resultingSelection: Self.rangeCiao, holdingCommand: false)
        try gesture(scene, resultingSelection: Self.rangeMondo, holdingCommand: true)
        try gesture(scene, resultingSelection: Self.rangeProva, holdingCommand: true)

        #expect(scene.model.multiSelectionPieces.count == 3)
    }

    @Test("a drag WITHOUT ⌘ after an accumulation clears the pieces")
    func plainDragAfterAccumulationClears() throws {
        let scene = try makeScene()
        defer { teardown(scene) }

        try gesture(scene, resultingSelection: Self.rangeCiao, holdingCommand: false)
        try gesture(scene, resultingSelection: Self.rangeMondo, holdingCommand: true)
        #expect(scene.model.multiSelectionPieces.count == 2)

        try gesture(scene, resultingSelection: Self.rangeProva, holdingCommand: false)
        #expect(scene.model.multiSelectionPieces.isEmpty, "a drag without ⌘ must reset the accumulated pieces")
    }

    @Test("Esc after an accumulation: DocumentModel.closeTransientOverlays clears the pieces and the native selection")
    func escClearsMultiSelection() throws {
        let scene = try makeScene()
        defer { teardown(scene) }

        try gesture(scene, resultingSelection: Self.rangeCiao, holdingCommand: false)
        try gesture(scene, resultingSelection: Self.rangeMondo, holdingCommand: true)
        #expect(scene.model.multiSelectionPieces.count == 2)
        #expect(scene.model.hasTransientOverlay)

        scene.model.closeTransientOverlays()
        #expect(scene.model.multiSelectionPieces.isEmpty)
        #expect(scene.pdfView.currentSelection == nil || scene.pdfView.currentSelection?.string?.isEmpty == true)
    }

    @Test("⌘⌥N on a multiple selection: one entry per piece, a single ⌘Z for the whole operation")
    func shortcutOnMultiSelectionCreatesOneEntryPerPieceAsOneUndoStep() throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        scene.model.analysisController.undoManager = scene.window.undoManager

        try gesture(scene, resultingSelection: Self.rangeCiao, holdingCommand: false)
        try gesture(scene, resultingSelection: Self.rangeMondo, holdingCommand: true)
        try gesture(scene, resultingSelection: Self.rangeProva, holdingCommand: true)
        #expect(scene.model.multiSelectionPieces.count == 3)

        scene.model.applyTocLevelShortcut(level: 2)

        #expect(scene.model.tocEntries.count == 3, "one piece → one entry")
        #expect(scene.model.tocEntries.allSatisfy { $0.level == 2 })
        #expect(scene.model.multiSelectionPieces.isEmpty, "the multiple selection must be consumed after the shortcut")

        // A single ⌘Z removes ALL THREE entries at once (a single operation,
        // as required), not one at a time.
        scene.window.undoManager?.undo()
        #expect(scene.model.tocEntries.isEmpty)
    }

    /// Visual check (PNG of a multiple selection): the REAL `PDFView` with two
    /// accumulated pieces, both still highlighted (PDFKit's native drawing of
    /// the combined `PDFSelection`), using the same `exportPNG` harness as
    /// `SidebarIndexLegendRenderTests`/`CollapsibleIndexRenderTests`.
    /// `RunLoop.current.run` pumps the main queue: `.PDFViewSelectionChanged`
    /// arrives with `queue: .main` (asynchronous even from the main thread,
    /// never synchronous at the time of `setCurrentSelection`), and the
    /// selection bar needs that turn to reconfigure itself before the capture.
    @Test("PNG: two pieces accumulated with ⌘ both stay highlighted, bar in T1-T4 mode")
    func multiSelectionScreenshot() throws {
        let scene = try makeScene()
        defer { teardown(scene) }

        try gesture(scene, resultingSelection: Self.rangeCiao, holdingCommand: false)
        try gesture(scene, resultingSelection: Self.rangeMondo, holdingCommand: true)
        for _ in 0 ..< 5 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

        #expect(scene.model.multiSelectionPieces.count == 2)
        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        exportPNG(scene.pdfView, to: outputRoot.appendingPathComponent("f10-3-multi-selection.png"))
    }
}
}
