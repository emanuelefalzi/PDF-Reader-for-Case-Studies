import Foundation
import AppKit
import SwiftUI
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// F4A: reported problem: "when I go full screen it takes 3 seconds and even
/// shows a hint of a loading spinner".
///
/// Cause found by reading the code (no profiler was available in that
/// session, the same limit noted elsewhere): `PDFView.autoScales = true`
/// fires `.PDFViewScaleChanged` on every frame of an animated resize (full
/// screen, dragged edge), and two heavy jobs ran on EVERY frame instead of
/// once at the end of the transition:
/// 1. `ScrollSyncCoordinator.rebuildAlignment()` → `AlignmentBuilder.build`,
///    which linearly scanned `context.blocks` for EVERY line of the document
///    (O(lines × blocks), see the fix in `Sync/AlignmentBuilder.swift`,
///    `blocksById`).
/// 2. The right panel (`RewriteScrollHost`) redid the layout of ALL the
///    cards (not lazy at the time, SPEC §5.6; the `Rewrite/` code was not to
///    be restructured) on every frame, because the width constraint of the
///    SwiftUI content followed the window in real time.
///
/// `WindowResizeCoalescer` (`Sync/WindowResizeCoalescer.swift`) signals the
/// start/end of the transition; `ScrollSyncCoordinator`/`RewriteScrollHost`/
/// `PDFReaderCoordinator` defer their heavy work to a single pass at the end.
/// This suite checks the coalescer on its own, then measures the real effect
/// on the right panel's relayout (quality target 1.1: "full relayout under
/// 300 ms, 70-page PDF, no spinner").
// `.serialized` like the other suites that create real `NSWindow`s (the M6
// test-host crash).
extension HeavyTestSuites {
@MainActor
@Suite("F4A: smoothness in full screen/resizing", .serialized)
struct WindowResizeCoalescerTests {
    // MARK: - The coalescer alone (no animated real NSWindow needed)

    @Test("begin/end are idempotent and post the notifications once per transition")
    func beginEndIdempotentAndPostsOnce() {
        let coalescer = WindowResizeCoalescer()
        var beganCount = 0
        var endedCount = 0
        let center = NotificationCenter.default
        let beginToken = center.addObserver(forName: .lelePdfResizeTransitionBegan, object: coalescer, queue: nil) { _ in beganCount += 1 }
        let endToken = center.addObserver(forName: .lelePdfResizeTransitionEnded, object: coalescer, queue: nil) { _ in endedCount += 1 }
        defer {
            center.removeObserver(beginToken)
            center.removeObserver(endToken)
        }

        #expect(coalescer.isTransitioning == false)
        // Simulates `willEnterFullScreen` and `willStartLiveResize` firing
        // almost together (the full-screen transition can trigger both): a
        // single logical "start", not two.
        coalescer.begin()
        coalescer.begin()
        #expect(coalescer.isTransitioning == true)
        #expect(beganCount == 1, "a repeated begin() without an end() in between must not post a second time")

        coalescer.end()
        coalescer.end()
        #expect(coalescer.isTransitioning == false)
        #expect(endedCount == 1, "a repeated end() without a begin() in between must not post a second time")

        // A second real transition works again (it is not a one-shot
        // "consumed" state).
        coalescer.begin()
        coalescer.end()
        #expect(beganCount == 2)
        #expect(endedCount == 2)
    }

    @Test("detach() stops the system notifications but does not touch the current state")
    func detachStopsObservingWithoutThrowing() {
        let coalescer = WindowResizeCoalescer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        coalescer.attach(to: window)
        coalescer.begin()
        #expect(coalescer.isTransitioning == true)
        coalescer.detach()
        // `detach()` also resets `isTransitioning` (implicit SPEC: a window
        // that is no longer observed cannot stay "stuck in transition"
        // forever).
        #expect(coalescer.isTransitioning == false)
    }

    // MARK: - Measurement: right-panel relayout when the size changes

    private func block(_ id: String, page: Int, pageBounds: CGRect, text: String) -> TextBlock {
        TextBlock(
            id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id,
            words: text.split(separator: " ").count,
            spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
            lineRectsByPage: [page: [pageBounds.insetBy(dx: 20, dy: 60)]]
        )
    }

    /// Synthetic 70-page document (quality target 1.1 "70-page PDF"), with 60
    /// analyzed blocks: a long paragraph plus a list per card, to really
    /// exercise the `MarkedNSTextView` layout under every `BlockCardView`
    /// (SPEC §5.6), not placeholder text.
    private func makeModelWithManyAnalyzedBlocks() throws -> DocumentModel {
        let pageCount = 70
        let analyzedBlockCount = 60
        let sourceURL = try StoreFixtures.makeMultiPageTextPDF(pageCount: pageCount, fileName: "resize-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "resize-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let longParagraph = String(
            repeating: "Paragrafo di prova abbastanza lungo da andare a capo più volte in un pannello di larghezza reale, così da esercitare davvero il calcolo dell'altezza di MarkedNSTextView sotto ogni scheda. ",
            count: 4
        )

        var analysis = AnalysisRecord()
        var blocks: [TextBlock] = []
        for i in 0 ..< analyzedBlockCount {
            let id = "b\(i)"
            guard let page = model.pdfDocument.page(at: i) else { continue }
            blocks.append(block(id, page: i, pageBounds: page.bounds(for: .mediaBox), text: longParagraph))
            analysis.blocks[id] = BlockAnalysis(
                status: .analyzed, title: "Blocco \(i)",
                rewrite: [
                    RewriteItem(kind: .summary, text: "Riassunto del blocco \(i)."),
                    RewriteItem(kind: .paragraph, text: longParagraph),
                    RewriteItem(kind: .bullets, items: ["Primo punto.", "Secondo punto, un poco più lungo del primo.", "Terzo punto."]),
                ]
            )
        }
        model.analysisController.updateContext(
            fingerprint: "fp-resize-perf", documentTitle: "Documento di prova", blocks: blocks,
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b\(analyzedBlockCount - 1)", tocEntries: []
        )
        return model
    }

    @Test("freezing the width during a transition reduces the right panel's total relayout time; the final pass stays under the SPEC threshold (quality target 1.1)")
    func coalescingReducesRewritePanelRelayoutTime() throws {
        let model = try makeModelWithManyAnalyzedBlocks()

        let viewportHeight: CGFloat = 700
        // No SwiftUI `.frame(width:height:)` on the content (unlike
        // `RewritePanelRealContentLayoutTests`, which never resizes after the
        // first pass): here the real width comes from the AppKit `frame` of
        // `hostingView`, changed at every simulated "frame" below, exactly as
        // the right panel's width comes from `RightPanel().frame(width:)` in
        // the real `ThreePaneLayout`, decided by the parent, not by the panel
        // itself.
        let hostingView = NSHostingView(rootView: RewritePanel().environment(model))
        hostingView.frame = CGRect(x: 0, y: 0, width: DSMetrics.rightPanelDefaultWidth, height: viewportHeight)

        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        // Intermediate frames of a realistic animated resize (SPEC §5.1: the
        // right panel is resizable between 320 and 520 pt): the same range
        // the panel crosses when the window animates (full screen/dragged
        // edge), even though its PREFERRED WIDTH does not change: without
        // freezing, each of these frames still redoes the layout of all the
        // cards.
        let widths: [CGFloat] = stride(from: DSMetrics.rightPanelMaxWidth, through: DSMetrics.rightPanelMinWidth, by: -12).map { $0 }

        func applyWidths() {
            for width in widths {
                hostingView.setFrameSize(NSSize(width: width, height: viewportHeight))
                hostingView.layoutSubtreeIfNeeded()
            }
        }

        // "Before" (no transition signaled, the behavior without the F4A
        // fix): every frame redoes the full layout of the 60 analyzed cards.
        let beforeStart = Date()
        applyWidths()
        let beforeMs = Date().timeIntervalSince(beforeStart) * 1000

        // "After" (transition signaled): the width stays frozen during all
        // the intermediate frames, a single real pass at `end()`
        // (`RewriteHostingCoordinator.unfreezeWidth`).
        model.windowResizeCoalescer.begin()
        let afterStart = Date()
        applyWidths()
        model.windowResizeCoalescer.end()
        let afterMs = Date().timeIntervalSince(afterStart) * 1000

        // Printed so the figures can be recorded (no profiler in this
        // session; the number reported comes from this run).
        print("F4A RESIZE-COALESCER right panel (\(widths.count) frames, 60 analyzed cards): before=\(beforeMs) ms · after=\(afterMs) ms")

        #expect(afterMs < beforeMs, "freezing during the transition should cost less than redoing the layout on every frame (before \(beforeMs) ms, after \(afterMs) ms)")
        // The real SPEC target (quality target 1.1): full relayout under 300
        // ms on a 70-page PDF. The "after" sequence also includes the SINGLE
        // real pass (`unfreezeWidth`, at `end()`), so it is the right number
        // to compare with that threshold, not the intermediate frames, which
        // are frozen and therefore at ~zero cost.
        #expect(afterMs < 300, "the coalesced relayout took \(afterMs) ms, above the SPEC threshold of 300 ms")
    }

    // MARK: - Measurement: AlignmentBuilder.build called several times (O(n²)→O(n) fix)

    @Test("AlignmentBuilder.build on 60 blocks stays fast even when called repeatedly, as during an animation without coalescing")
    func alignmentBuildStaysFastAcrossManyRebuilds() throws {
        let model = try makeModelWithManyAnalyzedBlocks()

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        let pdfWindow = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(pdfWindow) }
        pdfWindow.isReleasedWhenClosed = false
        pdfWindow.contentView = pdfView
        pdfWindow.layoutIfNeeded()
        let bridge = PDFReaderBridge(pdfView: pdfView)
        model.readerBridge = bridge

        // Synthetic row rectangles (no real `RewriteScrollHost` in this
        // test): only the 60 blocks matter for the linear scan this test is
        // meant to catch; see `blocksById` in `AlignmentBuilder.build`.
        var panelRowFrames: [String: CGRect] = [:]
        for i in 0 ..< 60 {
            panelRowFrames["b-b\(i)"] = CGRect(x: 0, y: CGFloat(i) * 96, width: DSMetrics.rightPanelDefaultWidth, height: 90)
        }

        // Like the dozens of `.PDFViewScaleChanged` notifications of a single
        // full-screen animation BEFORE the coalescing fix in
        // `ScrollSyncCoordinator` (this test deliberately bypasses it, to
        // measure the cost of ONE call × N, not the effect of coalescing,
        // already covered by the test above).
        let iterations = 30
        let start = Date()
        for _ in 0 ..< iterations {
            _ = AlignmentBuilder.build(model: model, panelRowFrames: panelRowFrames)
        }
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        print("F4A ALIGNMENT-BUILD \(iterations)× on 60 blocks: total=\(elapsedMs) ms (average \(elapsedMs / Double(iterations)) ms/call)")
        #expect(elapsedMs < 300, "AlignmentBuilder.build × \(iterations) took \(elapsedMs) ms; with the earlier linear scan (O(lines × blocks)) this number grew with blocks² instead of linearly")
    }
}
}
