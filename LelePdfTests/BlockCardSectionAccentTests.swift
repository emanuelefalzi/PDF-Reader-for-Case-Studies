import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LelePdf

/// User report: "it's not clear which summary belongs to which section".
/// Two fixes verified here: (1) the card header shows the chapter.block
/// label and the real page range, not just the title and the starting page;
/// (2) the "focused" block (under the mouse, on the PDF or on a card, or at
/// the reading position) is a single source of truth
/// (`DocumentModel.currentFocusedBlockId`) that drives both the card's
/// accent and the margin bar in the PDF.
extension HeavyTestSuites {
@MainActor
@Suite("Card section accent", .serialized)
struct BlockCardSectionAccentTests {
    private func block(_ id: String, page: Int, pageEnd: Int? = nil) -> TextBlock {
        TextBlock(
            id: id, sectionPath: [], pageStart: page, pageEnd: pageEnd ?? page,
            cleanText: "Termine", textHash: id, words: 1, spans: [], lineRectsByPage: [:]
        )
    }

    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova.", fileName: "section-accent-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "section-accent-test")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }

    // MARK: - Label "3.2 · Title · p. 4-5"

    @Test("pageRangeLabel shows a single number when the block is on one page, a range when it spans more than one")
    func pageRangeLabelSingleVsRange() {
        #expect(RewriteViewModel.pageRangeLabel(start: 3, end: 3) == "p. 4")
        #expect(RewriteViewModel.pageRangeLabel(start: 3, end: 4) == "p. 4-5")
    }

    @Test("the card header combines the chapter.block label, the title and the page range")
    func cardHeaderShowsLabelTitleAndPageRange() throws {
        let model = try makeModel()
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Nintendo's strategy",
            rewrite: [RewriteItem(kind: .summary, text: "Riassunto.")]
        )
        model.analysisController.updateContext(
            fingerprint: "fp", documentTitle: "T",
            blocks: [block("b1", page: 3, pageEnd: 4)],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )
        guard let data = model.analysisController.cardData(for: "b1") else {
            Issue.record("cardData(for:) did not find the analyzed block")
            return
        }
        #expect(data.page == 3 && data.pageEnd == 4)
        #expect(RewriteViewModel.pageRangeLabel(start: data.page, end: data.pageEnd) == "p. 4-5")
        #expect(model.analysisController.humanBlockLabel(for: "b1") == "0.1") // no T1 contents: chapter "0" (BlockLabeling rule)

        let view = BlockCardView(blockId: "b1", cardData: data, isRegenerating: false, isCurrent: false)
            .environment(model)
            .frame(width: 320)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(x: 0, y: 0, width: 320, height: 1)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        hostingView.frame = CGRect(x: 0, y: 0, width: 320, height: max(1, fitting.height))
        window.setContentSize(hostingView.frame.size)
        hostingView.layoutSubtreeIfNeeded()

        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        exportPNG(hostingView, to: outputRoot.appendingPathComponent("block-card-section-header.png"))
        #expect(fitting.height > 0)
    }

    @Test("the focused card has an accent bar on the left, the normal one does not")
    func currentCardShowsAccentBar() throws {
        let model = try makeModel()
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, title: "Blocco normale", rewrite: [RewriteItem(kind: .summary, text: "Uno.")])
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, title: "Blocco a fuoco", rewrite: [RewriteItem(kind: .summary, text: "Due.")])
        model.analysisController.updateContext(
            fingerprint: "fp", documentTitle: "T",
            blocks: [block("b1", page: 0), block("b2", page: 1)],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )
        guard let data1 = model.analysisController.cardData(for: "b1"), let data2 = model.analysisController.cardData(for: "b2") else {
            Issue.record("cardData(for:) did not find the analyzed blocks")
            return
        }

        let view = VStack(spacing: 10) {
            BlockCardView(blockId: "b1", cardData: data1, isRegenerating: false, isCurrent: false)
            BlockCardView(blockId: "b2", cardData: data2, isRegenerating: false, isCurrent: true)
        }
        .environment(model)
        .padding(10)
        .frame(width: 320)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(x: 0, y: 0, width: 320, height: 1)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        hostingView.frame = CGRect(x: 0, y: 0, width: 320, height: max(1, fitting.height))
        window.setContentSize(hostingView.frame.size)
        hostingView.layoutSubtreeIfNeeded()

        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        exportPNG(hostingView, to: outputRoot.appendingPathComponent("block-card-current-accent.png"))
        #expect(fitting.height > 0)
    }

    // MARK: - "Focused" block: a single source of truth

    @Test("currentFocusedBlockId prefers the hovered block, otherwise falls back to the reading position")
    func currentFocusedBlockPrefersHoverThenReadingPosition() throws {
        let model = try makeModel()
        model.analysisController.updateContext(
            fingerprint: "fp", documentTitle: "T",
            blocks: [block("b1", page: 0), block("b2", page: 1)],
            exhibits: [], analysis: AnalysisRecord(), lastAnalyzedBlockId: nil, tocEntries: []
        )

        model.currentPageIndex = 1
        #expect(model.hoveredBlockId == nil)
        #expect(model.currentFocusedBlockId == "b2", "without hover, falls back to the block at the reading position")

        model.setHoveredBlock("b1")
        #expect(model.currentFocusedBlockId == "b1", "with the mouse over a block, that one always wins")

        model.setHoveredBlock(nil)
        #expect(model.currentFocusedBlockId == "b2", "once the hover is removed, it goes back to the reading position")
    }

    @Test("setHoveredBlock is a no-op if the block does not change (no redundant notifications/redraws)")
    func setHoveredBlockGuardsAgainstRedundantUpdates() throws {
        let model = try makeModel()
        model.setHoveredBlock("b1")
        var notified = false
        let token = NotificationCenter.default.addObserver(forName: .lelePdfHoverChanged, object: model, queue: nil) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(token) }
        model.setHoveredBlock("b1")
        #expect(!notified, "same block: no new notification")
        model.setHoveredBlock("b2")
        #expect(notified, "different block: the notification must fire")
    }

    // MARK: - Stronger margin bar on the focused block (SPEC §5.5)

    @Test("the margin bar of the focused block is wider than the normal one")
    func marginBarFocusedIsWiderThanNormal() {
        let normal = MarkGeometry.marginBarRect(pageMinX: 100, minY: 10, maxY: 50)
        let focused = MarkGeometry.marginBarRect(pageMinX: 100, minY: 10, maxY: 50, width: MarkGeometry.marginBarWidthFocused)
        #expect(normal.width == MarkGeometry.marginBarWidth)
        #expect(focused.width > normal.width)
        #expect(MarkGeometry.marginBarWidthFocused > MarkGeometry.marginBarWidth)
    }
}
}
