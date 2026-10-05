import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// The real panel (`RewritePanel` in `RewriteScrollHost`, inside an
/// `NSWindow`) builds ONLY the cards around the visible part, still keeps the
/// height of the whole content, gives EVERY row a rectangle for linked
/// scrolling (SPEC §5.8) and, when scrolled to the bottom, builds the final
/// cards and releases the initial ones.
// `.serialized`: real `NSWindow`, like `RewritePanelRealContentLayoutTests`.
extension HeavyTestSuites {
@MainActor
@Suite("Lazy RewritePanel: only the cards in the window exist", .serialized)
struct RewritePanelLazyRealizationTests {
    private static let blockCount = 24

    private func block(_ id: String, page: Int, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id, words: text.split(separator: " ").count, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per il pannello pigro.", fileName: "lazy-panel-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "lazy-panel-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
        var analysis = AnalysisRecord()
        var blocks: [TextBlock] = []
        for i in 0 ..< Self.blockCount {
            let text = "Blocco \(i): " + String(repeating: "testo di prova abbastanza lungo da andare a capo più volte nella larghezza del pannello. ", count: 4)
            analysis.blocks["b\(i)"] = BlockAnalysis(status: .analyzed, title: "Scheda \(i)", rewrite: [RewriteItem(kind: .paragraph, text: text)])
            blocks.append(block("b\(i)", page: i, text: text))
        }
        model.analysisController.updateContext(fingerprint: "fp-lazy", documentTitle: "T", blocks: blocks, exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b23", tocEntries: [])
        return model
    }

    private func textViews(in view: NSView) -> [MarkedNSTextView] {
        var result: [MarkedNSTextView] = []
        if let text = view as? MarkedNSTextView { result.append(text) }
        for subview in view.subviews { result += textViews(in: subview) }
        return result
    }

    private func pump(_ hostingView: NSView, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            hostingView.layoutSubtreeIfNeeded()
        }
    }

    @Test("with 24 cards only those in the window exist; scrolling to the bottom builds the last ones and releases the first ones")
    func onlyWindowedCardsExist() throws {
        let model = try makeModel()
        let viewport = CGSize(width: DSMetrics.rightPanelDefaultWidth, height: 600)
        let hostingView = NSHostingView(rootView: RewritePanel().environment(model).frame(width: viewport.width, height: viewport.height))
        hostingView.frame = CGRect(origin: .zero, size: viewport)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        pump(hostingView, seconds: 0.6)

        let scrollView = try #require(model.rewriteScrollView)
        let documentView = try #require(scrollView.documentView)
        let geometry = model.rewritePanelGeometry

        let initial = textViews(in: documentView)
        #expect(initial.count >= 1)
        #expect(initial.count < Self.blockCount, "lazy panel: \(initial.count) text views for \(Self.blockCount) cards, they must not all exist")
        #expect(initial.contains { $0.string.hasPrefix("Blocco 0:") })
        #expect(!initial.contains { $0.string.hasPrefix("Blocco 23:") })

        let frames = geometry.rowFrames()
        #expect(frames.count == Self.blockCount, "one rectangle for every row, even an unbuilt one (SPEC §5.8)")
        let starts = (0 ..< Self.blockCount).map { frames["b-b\($0)"]!.minY }
        #expect(starts == starts.sorted())
        #expect(geometry.isMeasured("b-b0"))
        #expect(!geometry.isMeasured("b-b23"))
        let contentHeight = DocumentSpace.documentHeight(scrollView)
        #expect(contentHeight >= geometry.totalHeight, "the scrollable content covers the whole sequence (padding), not just the built cards")
        #expect(contentHeight > viewport.height * 3)

        // At the bottom: the last cards are built (and measured), the first ones are released.
        DocumentSpace.scroll(scrollView, topDownTop: DocumentSpace.maxScrollTopDown(scrollView))
        pump(hostingView, seconds: 0.8)
        let atBottom = textViews(in: scrollView.documentView!)
        #expect(atBottom.contains { $0.string.hasPrefix("Blocco 23:") }, "the last card is visible and therefore built")
        #expect(!atBottom.contains { $0.string.hasPrefix("Blocco 0:") }, "the first one has left the reserve and no longer exists")
        #expect(atBottom.count < Self.blockCount)
        #expect(geometry.isMeasured("b-b23"))
        #expect(geometry.isMeasured("b-b0"), "the measurement of a released card stays cached")
        let framesAfter = geometry.rowFrames()
        #expect(framesAfter.count == Self.blockCount)
        let visible = try #require(DocumentSpace.visibleTopDown(scrollView))
        let lastFrame = framesAfter["b-b23"]!
        #expect(lastFrame.maxY <= visible.top + visible.height + 1, "at the bottom, the last row's rectangle matches the real content (it ends within the visible part)")
    }
}
}
