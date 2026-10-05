import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// F8 (summary granularity): visual check of the REAL VIEWS of the two
/// controls: the start card in the right panel
/// (`RewritePanelGranularityControl`) and the "Summarise by: …" row in the
/// Contents tab (`ChaptersSidebarGranularity`). Same off-screen
/// `exportPNG`/`NSHostingView` harness as
/// `SidebarIndexLegendRenderTests`/`CollapsibleIndexRenderTests`, NEVER
/// `makeKeyAndOrderFront`. PNGs in
/// `~/Library/Caches/LelePdf/verifica-screenshots/`, read back after the
/// export.
///
/// **Design choice for this suite**: `RewritePanel` lives inside a real
/// `NSScrollView`, so there is no meaningful "fit to content" height
/// measurement from outside that would isolate the granularity card alone.
/// The check is therefore: (a) the real CONDITIONS behind
/// `RewritePanelGranularityControl.showsGranularityStartCard` (pure, no
/// SwiftUI), (b) the whole panel renders without crashing in both states and
/// produces a PNG that is readable for visual inspection.
extension HeavyTestSuites {
@MainActor
@Suite("F8: summary granularity control · visual check", .serialized)
struct SummaryGranularityRenderTests {
    private static let outputRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)

    private func makeModel(analyzed: Bool) throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per la grana del riassunto.", fileName: "grana-render-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "grana-render-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
        model.setColorTheme(.blu)
        model.tocEntries = [
            TocEntry(id: "t1", title: "Chapter 1 · Introduction", level: 1, page: 0),
            TocEntry(id: "t2", title: "1.1 Background", level: 2, page: 0),
        ]
        model.tocSource = .native

        let paragraphs = [PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(30))]
        let blocks = BlockSegmenter.segment(paragraphs: paragraphs)
        var analysis = AnalysisRecord()
        var progress = ProgressRecord()
        if analyzed, let first = blocks.first {
            analysis.blocks[first.id] = BlockAnalysis(status: .analyzed, title: "Blocco 1", rewrite: [RewriteItem(kind: .paragraph, text: "Testo.")])
            progress.analyzedBlockIds = [first.id]
        }
        model.analysisController.updateContext(
            fingerprint: "fp-render", documentTitle: "Documento di prova", blocks: blocks, exhibits: [],
            analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: model.tocEntries
        )
        // `RewritePanelGranularityControl.showsGranularityStartCard` looks at
        // `documentRecord.progress.analyzedBlockIds` (SPEC §5.5 "On
        // reopening"), not at `analysisController.context`; a real
        // `documentRecord` is needed in this test too, without a Store round trip.
        model.documentRecord = DocumentRecord.blank(fingerprint: "fp-render", fileName: "x.pdf", lastKnownPath: "/tmp/x.pdf", pageCount: 1, title: "X")
        model.documentRecord?.progress = progress
        model.currentPageIndex = 0
        return model
    }

    private func host(_ view: some View, width: CGFloat, height: CGFloat) -> (view: NSHostingView<AnyView>, window: NSWindow) {
        let hostingView = NSHostingView(rootView: AnyView(view.frame(width: width, height: height, alignment: .top)))
        hostingView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        return (hostingView, window)
    }

    @Test("right panel: 'Summarise by' card visible before the first analysis, at 320 pt")
    func startCardVisibleBeforeFirstAnalysis() throws {
        let model = try makeModel(analyzed: false)
        // The real conditions behind the card (SPEC "chosen once at the
        // start", `RewritePanelGranularityControl.showsGranularityStartCard`):
        // there is already something to segment and nothing has been analyzed yet.
        #expect(!(model.analysisController.context?.blocks.isEmpty ?? true))
        #expect(model.documentRecord?.progress.analyzedBlockIds.isEmpty == true)

        let view = RewritePanel().environment(model)
        let (hostingView, window) = host(view, width: 320, height: 420)
        defer { closeTestWindow(window) }
        exportPNG(hostingView, to: Self.outputRoot.appendingPathComponent("f8-granularity-start-card.png"))
        #expect(hostingView.fittingSize.height > 0)
    }

    @Test("right panel: 'Summarise by' card gone after the first analysis (SPEC 'chosen once at the start')")
    func startCardHiddenAfterFirstAnalysis() throws {
        let model = try makeModel(analyzed: true)
        #expect(model.documentRecord?.progress.analyzedBlockIds.isEmpty == false)

        let view = RewritePanel().environment(model)
        let (hostingView, window) = host(view, width: 320, height: 420)
        defer { closeTestWindow(window) }
        exportPNG(hostingView, to: Self.outputRoot.appendingPathComponent("f8-granularity-start-card-hidden.png"))
        #expect(hostingView.fittingSize.height > 0)
    }

    @Test("Contents tab: 'Summarise by: …' row always visible at the top")
    func chaptersSidebarShowsGranularityRow() throws {
        let model = try makeModel(analyzed: false)
        let view = ChaptersSidebar().environment(model)
        let (hostingView, window) = host(view, width: 260, height: 220)
        defer { closeTestWindow(window) }
        exportPNG(hostingView, to: Self.outputRoot.appendingPathComponent("f8-granularity-index-tab.png"))
        #expect(hostingView.fittingSize.height > 0)
    }
}
}
