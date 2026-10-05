import Foundation
import AppKit
import Testing
@testable import LelePdf

/// Pure math behind `AlignmentBuilder`'s knot-based polyline (line clusters,
/// covered text height), the common reading line in the window
/// (`DocumentSpace.readingLineOffsets`), the panel's "past the end" tail and
/// the explicit `drive` after a guarded jump.
@MainActor
@Suite("Sync: alignment knots")
struct AlignmentKnotsTests {
    private func line(_ top: CGFloat, height: CGFloat = 11) -> CGRect {
        // Page space: y grows upward; `top` here is measured "from the top" of
        // a page 800 pt tall.
        CGRect(x: 50, y: 800 - top - height, width: 400, height: height)
    }

    @Test("the lines of a paragraph stay together; a gap taller than the line spacing splits them")
    func clustersSplitAtParagraphGaps() {
        let rects = [line(100), line(114), line(128), line(160), line(174)] // 21 pt gap between 139 and 160
        let gap = AlignmentBuilder.clusterGap(for: rects)
        #expect(gap == max(AlignmentBuilder.clusterGapMin, 11 * AlignmentBuilder.clusterGapLines))
        let clusters = AlignmentBuilder.clusters(of: rects, gap: gap)
        #expect(clusters.count == 2)
        #expect(clusters[0].count == 3)
        #expect(clusters[1].count == 2)
        // Top to bottom: the first cluster is the highest one.
        #expect(clusters[0][0].maxY > clusters[1][0].maxY)
    }

    @Test("the covered text height merges split runs and ignores line spacing")
    func coveredHeightMergesRuns() {
        // Two runs on the same line (same y) count only once.
        let rects = [line(100), CGRect(x: 300, y: 800 - 100 - 11, width: 100, height: 11), line(114), line(140)]
        #expect(AlignmentBuilder.coveredHeight(of: rects) == 33)
        // Line spacing (3 pt between lines) is not text.
        #expect(AlignmentBuilder.coveredHeight(of: [line(0), line(14)]) == 22)
    }

    @Test("a gap above the threshold within the same page produces a second cluster; a title/figure does not consume a card")
    func figureGapProducesSeparateCluster() {
        let rects = [line(100), line(114), line(400), line(414), line(428)]
        let clusters = AlignmentBuilder.clusters(of: rects, gap: AlignmentBuilder.clusterGap(for: rects))
        #expect(clusters.count == 2)
        #expect(AlignmentBuilder.coveredHeight(of: clusters[0]) == 22)
        #expect(AlignmentBuilder.coveredHeight(of: clusters[1]) == 33)
    }

    private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

    private func scrollView(frame: CGRect, documentHeight: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView(frame: frame)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = FlippedDoc(frame: CGRect(x: 0, y: 0, width: frame.width, height: documentHeight))
        return scrollView
    }

    @Test("common reading line: 30% of the visible part of the PDF, at the same window height in the panel")
    func commonReadingLineInWindow() throws {
        // PDF: from top 40 to top 1040 of the window (1000 tall, AppKit y points up).
        // Panel: top 90 → 1040 (its header is 50 pt taller).
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 1080))
        let pdf = scrollView(frame: CGRect(x: 0, y: 40, width: 600, height: 1000), documentHeight: 5000)
        let panel = scrollView(frame: CGRect(x: 600, y: 40, width: 400, height: 950), documentHeight: 5000)
        content.addSubview(pdf)
        content.addSubview(panel)
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        let offsets = try #require(DocumentSpace.readingLineOffsets(pdf: pdf, panel: panel, fraction: 0.3))
        #expect(abs(offsets.pdf - 300) < 0.5, "30% of 1000 visible pt")
        // The line sits 300 pt below the top of the PDF (window top 40 from the
        // bottom = 1040): in the panel, which starts 50 pt lower, it is 250 pt
        // from its top, not 30% of its 950 (285).
        #expect(abs(offsets.panel - 250) < 0.5, "same window height, not 30% of the panel: \(offsets.panel)")
    }

    @Test("without a shared window each side keeps its own 30% (SPEC §5.8 to the letter)")
    func fallbackWithoutWindow() throws {
        let pdf = scrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 1000), documentHeight: 5000)
        let panel = scrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 500), documentHeight: 5000)
        let offsets = try #require(DocumentSpace.readingLineOffsets(pdf: pdf, panel: panel, fraction: 0.3))
        #expect(abs(offsets.pdf - 300) < 0.5)
        #expect(abs(offsets.panel - 150) < 0.5)
    }

    @Test("the tail past the end leaves the last card room to scroll up to the reading line")
    func scrollPastEndTail() {
        let tail = RewritePanelGeometry.scrollPastEndTail(viewportHeight: 1000)
        // Below the rows: 72 pt margin + ~60 for the button; the rest, up to
        // 70% of the visible part, is the tail.
        #expect(abs(tail - (700 - DSMetrics.rightPanelBottomMargin - 60)) < 0.5)
        #expect(RewritePanelGeometry.scrollPastEndTail(viewportHeight: 100) == 0)
    }

    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per i nodi.", fileName: "knots-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "knots-test")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }

    @Test("after a guarded jump, `followAfterNavigation` moves the panel after the PDF (jump from the contents with 'Follow the PDF' on)")
    func followAfterGuardedNavigation() async throws {
        let model = try makeModel()
        model.followPDF = true
        let coordinator = model.syncCoordinator
        let pdfSV = scrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), documentHeight: 1000)
        let panelSV = scrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 150), documentHeight: 1000)
        coordinator.attachPDF(scrollView: pdfSV, model: model)
        coordinator.attachPanel(scrollView: panelSV, model: model)
        coordinator.segments = [AlignmentSegment(id: "b1", pdfStart: 0, pdfHeight: 1000, panelStart: 0, panelHeight: 1000)]
        coordinator.performGuardedNavigation { DocumentSpace.scroll(pdfSV, topDownTop: 300) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(DocumentSpace.visibleTopDown(panelSV)?.top == 0, "the guard suppresses automatic synchronization")
        coordinator.followAfterNavigation(side: .pdf)
        // PDF: reading line at 300 + 90 = 390; panel: 390 − 45 = 345.
        #expect(abs((DocumentSpace.visibleTopDown(panelSV)?.top ?? 0) - 345) < 0.5)
        model.followPDF = false
        coordinator.performGuardedNavigation { DocumentSpace.scroll(pdfSV, topDownTop: 500) }
        coordinator.followAfterNavigation(side: .pdf)
        #expect(abs((DocumentSpace.visibleTopDown(panelSV)?.top ?? 0) - 345) < 0.5, "with 'Follow the PDF' off, nothing moves")
    }
}
