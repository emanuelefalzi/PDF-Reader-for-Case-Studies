import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// Investigation into the right panel being empty at times (a second
/// hypothesis, alongside the context-ordering race): `RewritePanel`/`RightPanel`
/// read `model.analysisController.documentOrderSegments()` only inside the
/// `content` closure passed to `RewriteScrollHost` (an `NSViewRepresentable`
/// that mounts a NESTED `NSHostingView`), not in the synchronous execution of
/// `RewritePanel`'s own `body`. It was suspected that SwiftUI's observation
/// (`@Observable`) would therefore not propagate outward, leaving the panel
/// "frozen" at the first closure until something else redrew an ancestor for
/// an unrelated reason (which would explain a panel that is empty "at times":
/// it would depend on the luck of an incidental redraw after the data
/// arrived).
///
/// **Verified here, and the theory does not hold**: a nested `NSHostingView`
/// is still an independent SwiftUI root with its own observation cycle.
/// Updating `model.analysisController` AFTER the first layout, without
/// touching any property read by the outer `body`
/// (`tocEntries`/`currentPageIndex`/`followPDF`, see `RightPanel.swift`), is
/// still reflected in the scrollable content. Kept as a permanent regression
/// test: if a future refactor changed this mechanism (for example by moving
/// the context read out of the `content` closure, or by introducing a cache
/// that is never invalidated), this test would catch it.
// `.serialized`: it creates a real `NSWindow`, for the same reason as
// `RewriteScrollHostTests`/`RewritePanelRealContentLayoutTests`.
extension HeavyTestSuites {
@MainActor
@Suite("RewritePanel · context arriving after the first layout is still reflected", .serialized)
struct RewritePanelLateContextObservationTests {
    private func block(_ id: String, page: Int, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id, words: text.split(separator: " ").count, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    @Test("a late updateContext, without touching tocEntries/currentPageIndex/followPDF, still grows the scrollable content")
    func lateContextUpdateReflectsInPanelWithoutTouchingUnrelatedState() throws {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per l'osservazione tardiva.", fileName: "late-context-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "late-context-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let viewportHeight: CGFloat = 600
        let hostingView = NSHostingView(rootView:
            RewritePanel()
                .environment(model)
                .frame(width: DSMetrics.rightPanelDefaultWidth, height: viewportHeight)
        )
        hostingView.frame = CGRect(x: 0, y: 0, width: DSMetrics.rightPanelDefaultWidth, height: viewportHeight)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false // never closed explicitly in this test, see RewriteScrollHostTests.
        window.contentView = hostingView

        // First layout: like the panel right after opening, before
        // structure/analysis arrive (empty rows, "Analysis in progress…").
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        let scrollView = try #require(model.rewriteScrollView)
        let heightBefore = DocumentSpace.documentHeight(scrollView)

        // The context arrives later (like `attachStructureToStore` after the
        // pipeline finishes), WITHOUT touching `tocEntries`/
        // `currentPageIndex`/`followPDF`, the only `DocumentModel` properties
        // read directly by `RightPanel.body` (outside the `RewriteScrollHost`
        // closure).
        let longParagraph = String(repeating: "Paragrafo di prova abbastanza lungo da andare a capo più volte nella larghezza reale del pannello. ", count: 8)
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, title: "Blocco arrivato in ritardo", rewrite: [RewriteItem(kind: .paragraph, text: longParagraph)])
        model.analysisController.updateContext(
            fingerprint: "fp-late", documentTitle: "T", blocks: [block("b1", page: 0, text: longParagraph)],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b1", tocEntries: []
        )

        // SwiftUI updates `NSHostingView`s by hooking into the run loop, not
        // synchronously when the observed property is set: give it a chance to
        // do so, as in a real interactive session.
        for _ in 0 ..< 10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hostingView.layoutSubtreeIfNeeded()
        }

        let heightAfter = DocumentSpace.documentHeight(scrollView)
        #expect(
            heightAfter > heightBefore + 50,
            "the panel did not update after a late updateContext that does not touch tocEntries/currentPageIndex/followPDF (heightBefore=\(heightBefore), heightAfter=\(heightAfter))"
        )
        #expect(model.analysisController.cardData(for: "b1") != nil)
    }
}
}
