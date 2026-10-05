import AppKit
import CoreImage
import Foundation
import Observation
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

@Suite("Review M10 · contents, prompt and rectangles")
struct ReviewM10PureTests {
    @Test("a reached pageY entry wins over a legacy entry on the same page")
    func positionedCurrentEntryWinsOverLegacyEntry() {
        let entries = [
            TocEntry(id: "precisa", title: "Precisa", level: 1, page: 3, pageY: 700),
            TocEntry(id: "legacy", title: "Legacy", level: 2, page: 3),
        ]

        #expect(TocNavigation.currentEntry(entries: entries, page: 3, pageY: 650)?.id == "precisa")
        #expect(TocNavigation.currentEntry(entries: entries, page: 3, pageY: 750)?.id == "legacy")
    }

    @Test("the mixed order is total: legacy as page start, then pageY from the top")
    func mixedTocOrderingIsDeterministic() {
        let entries = [
            TocEntryRecord(id: "legacy-1", title: "L1", level: 1, page: 2),
            TocEntryRecord(id: "basso", title: "Basso", level: 2, page: 2, pageY: 200),
            TocEntryRecord(id: "alto", title: "Alto", level: 2, page: 2, pageY: 700),
            TocEntryRecord(id: "legacy-2", title: "L2", level: 2, page: 2),
        ]

        let sorted = ManualToc.sorted(entries)
        #expect(sorted.map(\.id) == ["legacy-1", "legacy-2", "alto", "basso"])
        #expect(ManualToc.indentDepths(for: sorted) == [0, 1, 1, 1])
    }

    @Test("custom instructions keep the technical contract of the markers")
    func customInstructionsKeepMandatoryMarkerContract() throws {
        let custom = "Scrivi in modo molto sintetico."
        let prompt = try #require(AnalysisInstructions.systemPrompt(editableText: custom))

        #expect(prompt.contains(custom))
        #expect(prompt.contains(AnalysisInstructions.bundledContractText()))
        #expect(prompt.contains("{{mX|words shown}}"))
    }

    @Test("an empty custom file falls back to the bundle and cannot be saved")
    func blankCustomInstructionsAreRejectedAndIgnored() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lelepdf-review-m10-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "  \n".write(to: AnalysisInstructions.customFileURL(dataFolderURL: folder), atomically: true, encoding: .utf8)

        #expect(AnalysisInstructions.effectiveText(dataFolderURL: folder) == AnalysisInstructions.bundledText())
        #expect(throws: AnalysisInstructions.SaveError.self) {
            try AnalysisInstructions.save(" \n ", dataFolderURL: folder)
        }
    }

    @Test("two identical markIds in different blocks do not share overlay state")
    func rectangleOverlayIdentityIncludesBlock() {
        let first = PageMarkItem(
            blockId: "b1", markId: "m1", termId: "t1", type: .rectangle,
            isRepetition: false, hidden: false, pageIndex: 0, lineRects: []
        )
        let second = PageMarkItem(
            blockId: "b2", markId: "m1", termId: "t2", type: .rectangle,
            isRepetition: false, hidden: false, pageIndex: 0, lineRects: []
        )

        #expect(MarkOverlayState.fadeIdentifier(for: first, pageIndex: 0, offset: 0)
            != MarkOverlayState.fadeIdentifier(for: second, pageIndex: 0, offset: 1))
        #expect(MarkOverlayState.isSelected(first, markId: "m1", blockId: "b1"))
        #expect(!MarkOverlayState.isSelected(second, markId: "m1", blockId: "b1"))
    }

    @Test("the test host uses the staged PDFs and never resolves Desktop or Documents")
    func realPDFURLsStayOutsideProtectedFolders() {
        let protected = [
            FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].standardizedFileURL.path,
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path,
        ]
        for url in [TestPDFs.draghi, TestPDFs.merck] {
            #expect(protected.allSatisfy { !url.standardizedFileURL.path.hasPrefix($0) })
            #expect(url.standardizedFileURL.path.hasPrefix(TestPDFs.stagingDir.standardizedFileURL.path))
        }
    }

    @Test("chat and annotation preferences use the test host's isolated defaults domain")
    func preferencesUseAppRuntimeDefaults() {
        #expect(AppRuntime.isRunningUnderXCTest)
        #expect(ChatPreferences.defaultStore === AppRuntime.defaults)
        #expect(AnnotationToolMemory.defaultStore === AppRuntime.defaults)
    }
}

extension HeavyTestSuites {
@MainActor
@Suite("Review M10 · AppKit integration", .serialized)
struct ReviewM10AppKitTests {
    private final class FlippedContentView: NSView {
        override var isFlipped: Bool { true }
    }

    private func makeModel(pageCount: Int = 1) throws -> (DocumentModel, URL) {
        let url = try StoreFixtures.makeMultiPageTextPDF(
            pageCount: pageCount, fileName: "review-m10-\(UUID().uuidString).pdf"
        )
        let file = PDFFileDocument(data: try Data(contentsOf: url), displayName: "review-m10")
        return (try #require(DocumentModel(document: file, fileURL: url)), url)
    }

    @Test("the rectangle really uses CIMultiplyBlendMode and is transparent to events")
    func rectangleOverlayUsesMultiplyCompositingFilter() throws {
        let (model, url) = try makeModel()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        let overlay = RectangleMarksOverlay(model: model, pdfView: pdfView)
        let filter = overlay.layer?.compositingFilter as? CIFilter

        #expect(filter?.name == "CIMultiplyBlendMode")
        #expect(overlay.hitTest(.zero) == nil)
    }

    @Test("Esc closes chat and map together when both are open")
    func escapeActionClosesBothTransientOverlays() throws {
        let (model, url) = try makeModel()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.mapExpanded = true
        model.chatController.isPresented = true

        #expect(model.hasTransientOverlay)
        model.closeTransientOverlays()
        #expect(!model.mapExpanded)
        #expect(!model.chatController.isPresented)
        #expect(!model.hasTransientOverlay)
    }

    @Test("the document registry is observable and the Summary Lab follows the last active document")
    func openDocumentsPublishesActiveDocumentChanges() throws {
        let registry = OpenDocuments()
        let (first, firstURL) = try makeModel()
        let (second, secondURL) = try makeModel()
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        // `onChange` is `@Sendable`; the callback and the read happen in
        // sequence within the same MainActor test, a relationship the compiler
        // cannot deduce from Observation's generic signature.
        nonisolated(unsafe) var invalidated = false
        withObservationTracking {
            _ = registry.active
        } onChange: {
            invalidated = true
        }

        registry.register(first)
        #expect(invalidated)
        let viewModel = LaboratorioViewModel(openDocuments: registry)
        #expect(viewModel.document === first)
        registry.register(second)
        #expect(viewModel.document === second)
    }

    @Test("a click on a term in the panel updates the PDF's currentPageIndex")
    func panelTermClickUpdatesCurrentPage() throws {
        let (model, url) = try makeModel(pageCount: 5)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        let window = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = pdfView
        window.layoutIfNeeded()

        let bridge = PDFReaderBridge(pdfView: pdfView)
        model.readerBridge = bridge
        let pdfScrollView = try #require(bridge.enclosingScrollView)
        model.syncCoordinator.attachPDF(scrollView: pdfScrollView, model: model)
        let height = DocumentSpace.documentHeight(pdfScrollView)
        model.syncCoordinator.segments = [
            AlignmentSegment(id: "b-target", pdfStart: height * 0.8, pdfHeight: 100, panelStart: 0, panelHeight: 100),
        ]
        let block = TextBlock(
            id: "target", sectionPath: [], pageStart: 4, pageEnd: 4,
            cleanText: "Termine", textHash: "target", words: 1, spans: [], lineRectsByPage: [:]
        )
        var analysis = AnalysisRecord()
        analysis.blocks[block.id] = BlockAnalysis(status: .analyzed, marks: [
            Mark(id: "m1", termId: "t1", type: .rectangle, text: "Termine", source: .claude, page: 4, range: MarkRange(start: 0, length: 7)),
        ])
        model.analysisController.updateContext(
            fingerprint: "review-m10", documentTitle: "Test", blocks: [block], exhibits: [],
            analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )

        #expect(model.currentPageIndex == 0)
        model.syncCoordinator.handlePanelTermClicked(termId: "t1", markId: "m1", blockId: "target")
        #expect(model.currentPageIndex > 0)
        #expect(model.currentReadingPageY != nil)
        _ = window
    }
}
}
