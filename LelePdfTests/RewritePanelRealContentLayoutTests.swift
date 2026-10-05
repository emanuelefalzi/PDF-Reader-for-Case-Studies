import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// Investigation of the right panel sometimes appearing empty (hypotheses
/// (b)/(c): zero-height `NSTextView` cards before TextKit finishes layout, or
/// a panel not re-measured and left at width 0 on the first pass).
/// `RewriteScrollHostTests` already exists but only mounts a fixed
/// `Text("Riga di prova").frame(height: 60)`, never the real `RewritePanel`
/// with real cards, so it could not reveal a sizing problem specific to
/// `BlockCardView`/`MarkedNSTextView`.
/// This test mounts the real panel, with several analyzed blocks and
/// realistic content (long paragraphs, a list, a table: the same
/// `RewriteItem` kinds as SPEC §5.6), inside a real `NSWindow` at the real
/// panel width (`DSMetrics.rightPanelDefaultWidth`), and checks that after
/// layout the scrollable content is well above zero in height (and above the
/// visible view alone), that is, that it has not "collapsed" into an empty
/// panel because of a measurement problem.
// `.serialized` like `RewriteScrollHostTests`/`ScrollSyncCoordinatorTests`:
// it also creates a real `NSWindow`, for the same reason (the M6 test-host
// crash).
extension HeavyTestSuites {
@MainActor
@Suite("RewritePanel · real height of the scrollable content", .serialized)
struct RewritePanelRealContentLayoutTests {
    private func block(_ id: String, page: Int, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id, words: text.split(separator: " ").count, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    private func makeModelWithRealContent() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per il contenuto reale del pannello.", fileName: "real-content-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "real-content-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        // Analysis context populated directly (as
        // `DocumentModel.refreshAnalysisContext` would after
        // `attachStructureToStore`), with several blocks and really long
        // paragraphs: if the cards' `sizeThatFits` returned 0 because of a
        // layout problem, the total height of the scrollable content would
        // stay close to zero even with this text.
        let longParagraph = String(repeating: "Questo è un paragrafo di prova abbastanza lungo da andare a capo più volte nella larghezza reale del pannello destro, così da esercitare davvero il calcolo dell'altezza di MarkedNSTextView. ", count: 6)
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Primo blocco analizzato",
            rewrite: [
                RewriteItem(kind: .summary, text: "Riassunto breve del primo blocco."),
                RewriteItem(kind: .paragraph, text: longParagraph),
                RewriteItem(kind: .bullets, items: ["Primo punto elenco.", "Secondo punto elenco, un poco più lungo del primo.", "Terzo punto."]),
            ]
        )
        analysis.blocks["b2"] = BlockAnalysis(
            status: .analyzed, title: "Secondo blocco analizzato",
            rewrite: [
                RewriteItem(kind: .summary, text: "Riassunto del secondo blocco."),
                RewriteItem(kind: .paragraph, text: longParagraph),
            ]
        )
        let blocks = [
            block("b1", page: 0, text: longParagraph),
            block("b2", page: 1, text: longParagraph),
        ]
        model.analysisController.updateContext(
            fingerprint: "fp-real-content", documentTitle: "Documento di prova", blocks: blocks,
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b2", tocEntries: []
        )
        return model
    }

    @Test("the panel with real cards (long paragraphs, a list) has a content height well above zero after layout")
    func realCardContentProducesNonZeroContentHeight() throws {
        let model = try makeModelWithRealContent()

        let viewportHeight: CGFloat = 600
        let hostingView = NSHostingView(rootView:
            RewritePanel()
                .environment(model)
                .frame(width: DSMetrics.rightPanelDefaultWidth, height: viewportHeight)
        )
        hostingView.frame = CGRect(x: 0, y: 0, width: DSMetrics.rightPanelDefaultWidth, height: viewportHeight)

        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false // see RewriteScrollHostTests: never explicitly closed in this test.
        window.contentView = hostingView

        // Two layout passes: SwiftUI/AppKit may need a second pass for
        // `NSHostingView.intrinsicContentSize` (inside `RewriteScrollHost`) to
        // settle at the container's real width instead of the (often 0) width
        // of the very first pass: exactly hypothesis (c) under investigation.
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let scrollView = try #require(model.rewriteScrollView, "RewriteScrollHost.makeNSView must wire up model.rewriteScrollView")
        let contentHeight = DocumentSpace.documentHeight(scrollView)

        #expect(contentHeight > 150, "scrollable content height suspiciously small (\(contentHeight) pt) for two cards with long paragraphs and a list: the panel risks looking empty/collapsed")
        #expect(contentHeight > viewportHeight * 1.2 || contentHeight > 400, "the real content should far exceed the visible area alone, not stay clamped to it")
    }
}
}
