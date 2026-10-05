import Foundation
import AppKit
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// Regressions found while reviewing the PDF reader, each with its own check
/// on a REAL `PDFView`/`MarksOverlayView` inside a window (same scheme as
/// `MultiSelectionRealEventTests`/`MarksOverlayZoomGeometryTests`).
extension HeavyTestSuites {
@MainActor
@Suite("PDF reader review: mini bar, hover, zoom, multi-selection", .serialized)
struct ReaderReviewF17Tests {
    private struct Scene {
        let model: DocumentModel
        let pdfView: PDFView
        let overlay: MarksOverlayView
        let coordinator: PDFReaderCoordinator
        let window: NSWindow
        let page: PDFPage
    }

    /// Six 300×400 pt pages ("Pagina N di 6"), a 300×200 pt viewport (so it
    /// can scroll), one block on the first page with an `.underline` mark on
    /// the word "Pagina".
    private func makeScene() throws -> Scene {
        let sourceURL = try StoreFixtures.makeMultiPageTextPDF(pageCount: 6, fileName: "f17-reader-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "f17-reader-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
        let page = try #require(model.pdfDocument.page(at: 0))

        let text = "Pagina 1 di 6"
        let block = TextBlock(
            id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, cleanText: text, textHash: "h1", words: 4,
            spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
            lineRectsByPage: [:]
        )
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Blocco",
            marks: [Mark(id: "m1", termId: "t1", type: .underline, text: "Pagina", source: .claude, page: 0, range: MarkRange(start: 0, length: 6))]
        )
        model.analysisController.updateContext(
            fingerprint: "fp-f17-reader", documentTitle: "T", blocks: [block],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1

        let window = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pdfView

        let coordinator = PDFReaderCoordinator()
        coordinator.attach(to: pdfView, model: model)
        let bridge = PDFReaderBridge(pdfView: pdfView)
        model.readerBridge = bridge

        let overlay = MarksOverlayView(model: model, pdfView: pdfView)
        overlay.frame = pdfView.bounds
        pdfView.addSubview(overlay)
        bridge.marksOverlay = overlay
        model.visiblePageRange = 0 ... 0

        window.layoutIfNeeded()
        window.makeKeyAndOrderFront(nil)
        spin()
        return Scene(model: model, pdfView: pdfView, overlay: overlay, coordinator: coordinator, window: window, page: page)
    }

    private func teardown(_ scene: Scene) {
        scene.overlay.stopObserving()
        scene.overlay.removeFromSuperview()
        scene.coordinator.detach()
        if let fileURL = scene.model.fileURL { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        closeTestWindow(scene.window)
    }

    private func spin(_ turns: Int = 3) {
        for _ in 0 ..< turns { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func selectWord(_ scene: Scene, range: NSRange) throws {
        let selection = try #require(scene.page.selection(for: range))
        scene.pdfView.setCurrentSelection(selection, animate: false)
    }

    private func mouseEvent(_ type: NSEvent.EventType, scene: Scene, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        let point = scene.overlay.convert(CGPoint(x: scene.overlay.bounds.midX, y: scene.overlay.bounds.midY - 40), to: nil)
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: scene.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    private func markCenter(_ scene: Scene) throws -> CGPoint {
        let entry = try #require(scene.overlay.hitItems(forPage: 0).first { $0.item.markId == "m1" })
        let rect = try #require(entry.rects.first)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: - Mini bar on mouse-up

    @Test("with no button pressed (keyboard/accessibility) the mini bar appears immediately, as before")
    func selectionBarAppearsImmediatelyWithoutMouseDown() throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        scene.overlay.isLeftMouseButtonPressed = { false }

        try selectWord(scene, range: NSRange(location: 0, length: 6))
        #expect(scene.overlay.selectionBar.isHidden == false)
        #expect(scene.overlay.selectionBarRefreshPending == false)
    }

    @Test("during a drag the bar stays hidden and is not rebuilt; on mouse-up it appears exactly once")
    func selectionBarWaitsForMouseUp() throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        scene.overlay.isLeftMouseButtonPressed = { true }

        // Three "drag events": the selection grows, the bar does not.
        for length in [3, 6, 9] { try selectWord(scene, range: NSRange(location: 0, length: length)) }
        #expect(scene.overlay.selectionBar.isHidden, "the bar must not appear while the button is pressed")
        #expect(scene.overlay.selectionBarRefreshPending, "an update must stay pending until mouse-up")

        scene.overlay.isLeftMouseButtonPressed = { false }
        scene.overlay.handleSelectionBarMouseUp()
        #expect(scene.overlay.selectionBarRefreshPending == false)
        spin()
        #expect(scene.overlay.selectionBar.isHidden == false, "on mouse-up the bar appears on the final selection")
        #expect(scene.overlay.selectionBar.subviews.contains { $0 is NSButton })
    }

    @Test("empty selection on mouse-up: the bar stays hidden")
    func selectionBarStaysHiddenWhenSelectionEmptyAtMouseUp() throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        scene.overlay.isLeftMouseButtonPressed = { true }
        try selectWord(scene, range: NSRange(location: 0, length: 6))
        scene.pdfView.setCurrentSelection(nil, animate: false)
        scene.overlay.isLeftMouseButtonPressed = { false }
        scene.overlay.handleSelectionBarMouseUp()
        spin()
        #expect(scene.overlay.selectionBar.isHidden)
    }

    // MARK: - The bar follows scrolling

    @Test("after scrolling, the mini bar stays above the selection (it moves with the page)")
    func selectionBarFollowsScroll() throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        scene.overlay.isLeftMouseButtonPressed = { false }
        try selectWord(scene, range: NSRange(location: 0, length: 6))
        #expect(scene.overlay.selectionBar.isHidden == false)
        let anchor = try #require(scene.overlay.selectionBarAnchor)
        let before = scene.overlay.selectionBar.frame

        let scrollView = try #require(scene.pdfView.documentView?.enclosingScrollView)
        let top = DocumentSpace.visibleTopDown(scrollView)?.top ?? 0
        DocumentSpace.scroll(scrollView, topDownTop: top + 37)
        spin()

        let after = scene.overlay.selectionBar.frame
        #expect(after != before, "the bar must move together with the text, not stay where it was")
        // Same position that `place` would give by converting the anchor again.
        let expectedRect = scene.pdfView.convert(anchor.pageRect, from: anchor.page)
        let expectedBelow = expectedRect.minY - after.height - 6
        let expectedAbove = expectedRect.maxY + 6
        #expect(abs(after.origin.y - expectedAbove) < 0.5 || abs(after.origin.y - expectedBelow) < 0.5,
                "bar at y=\(after.origin.y), expected \(expectedAbove) (above) or \(expectedBelow) (below)")
    }

    // MARK: - Hover: shortcut invalidated on scroll/changed marks

    @Test("the hover shortcut (rectangles in view space) is cleared on every scroll and every invalidate()")
    func hoverShortcutClearedOnScrollAndInvalidate() throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        let center = try markCenter(scene)

        scene.overlay.handleMouseMoved(at: center)
        #expect(scene.overlay.currentHoverEntry != nil)
        #expect(scene.model.hoveredMarkId == "m1")

        let scrollView = try #require(scene.pdfView.documentView?.enclosingScrollView)
        let top = DocumentSpace.visibleTopDown(scrollView)?.top ?? 0
        DocumentSpace.scroll(scrollView, topDownTop: top + 50)
        spin()
        #expect(scene.overlay.currentHoverEntry == nil, "after scrolling the view-space rectangles are stale: no shortcut")

        // The mouse is still at the same point in the view: the mark has
        // slid away, and the next event must notice.
        scene.overlay.handleMouseMoved(at: center)
        #expect(scene.model.hoveredMarkId == nil, "the mark is no longer under the cursor after scrolling 50 pt")

        DocumentSpace.scroll(scrollView, topDownTop: top)
        spin()
        scene.overlay.handleMouseMoved(at: try markCenter(scene))
        #expect(scene.overlay.currentHoverEntry != nil)
        scene.overlay.invalidate()
        #expect(scene.overlay.currentHoverEntry == nil)
    }

    // MARK: - ⌃+wheel is not blocked by search/multi-selection

    @Test("the reader gesture block applies only to chat and the expanded map, not to open search or multi-selection")
    func readerGesturesBlockedOnlyByChatAndMap() throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        let model = scene.model
        #expect(model.readerGesturesBlockedByOverlay == false)

        model.searchQuery = "Pagina"
        #expect(model.hasTransientOverlay, "Esc must still close the search")
        #expect(model.readerGesturesBlockedByOverlay == false, "zooming stays possible with search open")

        let selection = try #require(scene.page.selection(for: NSRange(location: 0, length: 6)))
        model.multiSelectionPieces = [selection]
        #expect(model.readerGesturesBlockedByOverlay == false, "zooming stays possible while a ⌘ selection is being accumulated")
        model.searchQuery = ""
        model.multiSelectionPieces = []

        model.openExpandedMap()
        #expect(model.readerGesturesBlockedByOverlay)
        model.closeExpandedMap()
        model.chatController.isPresented = true
        #expect(model.readerGesturesBlockedByOverlay)
        model.chatController.isPresented = false
        #expect(model.readerGesturesBlockedByOverlay == false)
    }

    @Test("the ⌃+wheel monitor accepts a point over the PDF with search open and rejects it with the expanded map")
    func wheelZoomMonitorUsesTheNarrowGate() throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        let location = scene.pdfView.convert(CGPoint(x: 150, y: 100), to: nil)

        scene.model.searchQuery = "Pagina"
        #expect(scene.coordinator.zoomAnchorPointIgnoringActivation(window: scene.window, locationInWindow: location) != nil)
        scene.model.searchQuery = ""

        scene.model.openExpandedMap()
        #expect(scene.coordinator.zoomAnchorPointIgnoringActivation(window: scene.window, locationInWindow: location) == nil)
        scene.model.closeExpandedMap()

        let otherWindow = NSWindow(contentRect: scene.pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { closeTestWindow(otherWindow) }
        #expect(scene.coordinator.zoomAnchorPointIgnoringActivation(window: otherWindow, locationInWindow: location) == nil, "an event from another window is not ours")
        #expect(scene.coordinator.zoomAnchorPointIgnoringActivation(window: scene.window, locationInWindow: CGPoint(x: -50, y: -50)) == nil, "outside the PDF")
    }

    // MARK: - ⌘-drag with the Annotate bar on a tool

    @Test("with the Annotate bar on Highlight, ⌘-drag does not start a multi-selection (the click goes to the annotation overlay)")
    func commandGestureIgnoredWhileAnnotationToolActive() throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        let controller = scene.model.annotationController
        controller.barVisible = true
        controller.selectTool(.highlight)

        scene.overlay.handleMultiSelectionMouseDown(mouseEvent(.leftMouseDown, scene: scene, modifiers: [.command]))
        #expect(scene.overlay.isAccumulatingMultiSelectionGesture == false)
        try selectWord(scene, range: NSRange(location: 0, length: 6))
        scene.overlay.handleMultiSelectionMouseUp(mouseEvent(.leftMouseUp, scene: scene, modifiers: [.command]))
        #expect(scene.model.multiSelectionPieces.isEmpty)
        #expect(scene.model.hasTransientOverlay == false)

        // With the Select tool (clicks go back to native selection) the gesture applies.
        controller.selectTool(.select)
        scene.overlay.handleMultiSelectionMouseDown(mouseEvent(.leftMouseDown, scene: scene, modifiers: [.command]))
        #expect(scene.overlay.isAccumulatingMultiSelectionGesture)
        try selectWord(scene, range: NSRange(location: 7, length: 1))
        scene.overlay.handleMultiSelectionMouseUp(mouseEvent(.leftMouseUp, scene: scene, modifiers: [.command]))
        #expect(scene.model.multiSelectionPieces.count == 2, "the existing selection and the new piece")
    }

    // MARK: - Teardown: the tracking area too

    @Test("stopObserving also removes the mouse tracking area (parity with AnnotationOverlayView)")
    func stopObservingRemovesTrackingArea() throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        scene.overlay.updateTrackingAreas()
        #expect(!scene.overlay.trackingAreas.isEmpty)
        scene.overlay.stopObserving()
        #expect(scene.overlay.trackingAreas.isEmpty)
    }
}
}
