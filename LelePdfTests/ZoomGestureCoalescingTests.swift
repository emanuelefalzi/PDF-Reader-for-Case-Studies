import Foundation
import AppKit
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// F4Z: a burst of ⌃+wheel/pinch (`PDFReaderCoordinator+WheelZoom.swift`)
/// calls `pdfView.scaleFactor = ...` on every single tick, which in turn
/// posts `.PDFViewScaleChanged` → `PDFReaderCoordinator.handleScaleChanged()`
/// → `ScrollSyncCoordinator.rebuildAlignment()`. Without coalescing,
/// `AlignmentBuilder.build` (a pass over the whole document, not just the
/// visible pages) would run once for EVERY tick of the burst, the exact same
/// problem as F4A (`WindowResizeCoalescerTests.swift`), this time for zoom
/// instead of window resizing. This suite verifies the SEPARATE gate added to
/// `ScrollSyncCoordinator` (`beginZoomGesture`/`endZoomGesture`, not the
/// `WindowResizeCoalescer` notifications; see the comment on that gate for
/// why: reusing those notifications would switch `autoScales` off and on
/// again and cancel the zoom just chosen).
extension HeavyTestSuites {
@MainActor
@Suite("F4Z: rebuild coalescing during a zoom burst", .serialized)
struct ZoomGestureCoalescingTests {
    private func block(_ id: String, page: Int, pageBounds: CGRect, text: String) -> TextBlock {
        TextBlock(
            id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id,
            words: text.split(separator: " ").count,
            spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
            lineRectsByPage: [page: [pageBounds.insetBy(dx: 20, dy: 60)]]
        )
    }

    /// A document with analyzed blocks and a real `PDFReaderBridge`, so
    /// `AlignmentBuilder.build` really does its work (not an immediate `[]`
    /// because `readerBridge == nil`), same scheme as
    /// `WindowResizeCoalescerTests.alignmentBuildStaysFastAcrossManyRebuilds`.
    private func makeModelReadyForAlignment(blockCount: Int) throws -> DocumentModel {
        let pageCount = max(blockCount, 1)
        let sourceURL = try StoreFixtures.makeMultiPageTextPDF(pageCount: pageCount, fileName: "zoom-coalesce-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "zoom-coalesce-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        var analysis = AnalysisRecord()
        var blocks: [TextBlock] = []
        for i in 0 ..< blockCount {
            let id = "b\(i)"
            guard let page = model.pdfDocument.page(at: i) else { continue }
            blocks.append(block(id, page: i, pageBounds: page.bounds(for: .mediaBox), text: "Blocco di prova numero \(i), con un po' di testo."))
            analysis.blocks[id] = BlockAnalysis(status: .analyzed, title: "Blocco \(i)", rewrite: [RewriteItem(kind: .summary, text: "Riassunto del blocco \(i).")])
        }
        model.analysisController.updateContext(
            fingerprint: "fp-zoom-coalesce", documentTitle: "Documento di prova", blocks: blocks,
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b\(blockCount - 1)", tocEntries: []
        )

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        let window = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = pdfView
        window.layoutIfNeeded()
        model.readerBridge = PDFReaderBridge(pdfView: pdfView)
        // `ScrollSyncCoordinator.model` (weak) is only set by
        // `attachPDF`/`attachPanel`; without one of the two,
        // `rebuildAlignment()` returns immediately (`guard let model`) and
        // `AlignmentBuilder.build` never runs, regardless of the burst gate:
        // here attaching the PDF side is enough, no real right panel is
        // needed for this test.
        if let scrollView = model.readerBridge?.enclosingScrollView {
            model.syncCoordinator.attachPDF(scrollView: scrollView, model: model)
        }

        var panelRowFrames: [String: CGRect] = [:]
        for i in 0 ..< blockCount {
            panelRowFrames["b-b\(i)"] = CGRect(x: 0, y: CGFloat(i) * 96, width: DSMetrics.rightPanelDefaultWidth, height: 90)
        }
        model.syncCoordinator.updatePanelRowFrames(panelRowFrames)
        return model
    }

    // MARK: - Correctness: deferred during the burst, executed once at the end

    @Test("rebuildAlignment() called several times during a burst rebuilds nothing; endZoomGesture() does it once")
    func rebuildIsDeferredThenExecutedOnce() throws {
        let model = try makeModelReadyForAlignment(blockCount: 5)
        let coordinator = model.syncCoordinator

        // "Real" state after the `updatePanelRowFrames` above (already one build).
        let segmentsBeforeBurst = coordinator.segments
        #expect(!segmentsBeforeBurst.isEmpty)

        coordinator.beginZoomGesture()
        // A realistic burst: many ticks, many `.PDFViewScaleChanged`.
        for _ in 0 ..< 20 {
            coordinator.rebuildAlignment()
        }
        // Deferred for the whole burst: `segments` was not touched.
        #expect(coordinator.segments == segmentsBeforeBurst, "a `rebuildAlignment()` during the burst must not rebuild anything")

        // A real change of the panel's rectangles during the burst (as
        // `RewriteScrollHost` would on every frame): `updatePanelRowFrames`
        // calls `rebuildAlignment()` internally, but it is still deferred by
        // the same gate.
        var changedFrames: [String: CGRect] = [:]
        for i in 0 ..< 5 { changedFrames["b-b\(i)"] = CGRect(x: 0, y: CGFloat(i) * 200, width: DSMetrics.rightPanelDefaultWidth, height: 190) }
        coordinator.updatePanelRowFrames(changedFrames)
        #expect(coordinator.segments == segmentsBeforeBurst, "a change of the panel's rectangles during the burst must not rebuild immediately")

        coordinator.endZoomGesture()
        // At the end of the burst, the real rebuild uses the updated
        // rectangles: `segments` changed compared to before the burst.
        #expect(coordinator.segments != segmentsBeforeBurst)
        #expect(!coordinator.segments.isEmpty)
    }

    @Test("begin/end are idempotent: a repeated begin does not reopen an already closed burst, an end without a begin does nothing")
    func beginEndIdempotent() throws {
        let model = try makeModelReadyForAlignment(blockCount: 3)
        let coordinator = model.syncCoordinator
        let before = coordinator.segments

        coordinator.beginZoomGesture()
        coordinator.beginZoomGesture() // repeated: no additional effect
        coordinator.rebuildAlignment()
        #expect(coordinator.segments == before)

        coordinator.endZoomGesture()
        let afterFirstEnd = coordinator.segments
        #expect(!afterFirstEnd.isEmpty)

        // A second `endZoomGesture()` without a new burst must not redo
        // `AlignmentBuilder.build` (no pending rebuild).
        coordinator.endZoomGesture()
        #expect(coordinator.segments == afterFirstEnd)
    }

    // MARK: - Measurement (like `WindowResizeCoalescerTests`)

    @Test("measurement: a burst of 40 zoom ticks with coalescing costs a single AlignmentBuilder.build, not 40")
    func burstOfZoomEventsCostsOneRebuildNotForty() throws {
        let model = try makeModelReadyForAlignment(blockCount: 40)
        let coordinator = model.syncCoordinator
        let iterations = 40

        // "Before" (no coalescing, as if every tick really rebuilt): the real
        // cost of 40 `AlignmentBuilder.build` calls in a row.
        let beforeStart = Date()
        for _ in 0 ..< iterations {
            coordinator.rebuildAlignment()
        }
        let beforeMs = Date().timeIntervalSince(beforeStart) * 1000

        // "After" (F4Z coalescing active): the 40 calls during the burst are
        // no-ops, a single real rebuild at `endZoomGesture()`.
        coordinator.beginZoomGesture()
        let afterStart = Date()
        for _ in 0 ..< iterations {
            coordinator.rebuildAlignment()
        }
        coordinator.endZoomGesture()
        let afterMs = Date().timeIntervalSince(afterStart) * 1000

        print("F4Z ZOOM-COALESCER (\(iterations) ticks, 40 analyzed blocks): before=\(beforeMs) ms · after=\(afterMs) ms")
        #expect(afterMs < beforeMs, "the coalesced burst should cost less than the \(iterations) real rebuilds (before \(beforeMs) ms, after \(afterMs) ms)")
        #expect(afterMs < 300, "the coalesced burst took \(afterMs) ms, above the SPEC threshold of 300 ms")
    }
}
}
