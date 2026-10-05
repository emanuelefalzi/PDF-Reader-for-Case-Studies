import Foundation
import AppKit
import Testing
@testable import LelePdf

/// `DocumentSpace` (SPEC §5.8, `Sync/DocumentSpace.swift`): reading/writing
/// the scroll position in the "scroll-down" space shared by both sides, with
/// real `NSScrollView`s but outside a window (enough for geometry alone).
@MainActor
@Suite("Sync: DocumentSpace")
struct DocumentSpaceTests {
    private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }
    private final class UnflippedDoc: NSView {}

    private func scrollView(flipped: Bool, documentHeight: CGFloat, viewportHeight: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: viewportHeight))
        let doc: NSView = flipped
            ? FlippedDoc(frame: CGRect(x: 0, y: 0, width: 300, height: documentHeight))
            : UnflippedDoc(frame: CGRect(x: 0, y: 0, width: 300, height: documentHeight))
        scrollView.documentView = doc
        scrollView.contentView.setFrameSize(NSSize(width: 300, height: viewportHeight))
        return scrollView
    }

    @Test("maximum scroll = document height − visible height")
    func maxScrollTopDown() {
        #expect(DocumentSpace.maxScrollTopDown(scrollView(flipped: true, documentHeight: 1000, viewportHeight: 300)) == 700)
        #expect(DocumentSpace.maxScrollTopDown(scrollView(flipped: false, documentHeight: 1000, viewportHeight: 300)) == 700)
    }

    @Test("scrolling and reading the position back give the same result, flipped or not")
    func scrollRoundTripBothOrientations() {
        for flipped in [true, false] {
            let sv = scrollView(flipped: flipped, documentHeight: 1000, viewportHeight: 300)
            DocumentSpace.scroll(sv, topDownTop: 250)
            let visible = DocumentSpace.visibleTopDown(sv)
            #expect(visible?.top == 250, "flipped=\(flipped)")
            #expect(visible?.height == 300, "flipped=\(flipped)")
        }
    }

    @Test("scrolling past the bottom is clamped")
    func scrollClampedAtBottom() {
        let sv = scrollView(flipped: true, documentHeight: 1000, viewportHeight: 300)
        let applied = DocumentSpace.scroll(sv, topDownTop: 5000)
        #expect(applied == 700)
        #expect(DocumentSpace.visibleTopDown(sv)?.top == 700)
    }

    @Test("scrolling below zero is clamped")
    func scrollClampedAtTop() {
        let sv = scrollView(flipped: true, documentHeight: 1000, viewportHeight: 300)
        let applied = DocumentSpace.scroll(sv, topDownTop: -50)
        #expect(applied == 0)
    }
}

/// `ScrollSyncCoordinator` (SPEC §5.8): anti-bounce guard, "Follow the PDF"
/// toggle, click on a linked mark/term. `.serialized` like the other suites
/// that touch the shared `AppStore.shared`/`UserDefaults` through
/// `DocumentModel` (see `DocumentModelStoreIntegrationTests`).
extension HeavyTestSuites {
@MainActor
@Suite("Sync: ScrollSyncCoordinator", .serialized)
struct ScrollSyncCoordinatorTests {
    private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

    private func scrollView(documentHeight: CGFloat, viewportHeight: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: viewportHeight))
        let doc = FlippedDoc(frame: CGRect(x: 0, y: 0, width: 300, height: documentHeight))
        scrollView.documentView = doc
        scrollView.contentView.setFrameSize(NSSize(width: 300, height: viewportHeight))
        return scrollView
    }

    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per lo scorrimento collegato.", fileName: "sync-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "sync-test")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }

    private func block(_ id: String, page: Int) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: "Testo.", textHash: id, words: 2, spans: [], lineRectsByPage: [:])
    }

    private func pump() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    @Test("a programmatic scroll does not re-trigger synchronization (no bounce-back)")
    func noBounceBack() async throws {
        let model = try makeModel()
        model.followPDF = true
        let coordinator = model.syncCoordinator
        let pdfSV = scrollView(documentHeight: 1000, viewportHeight: 300)
        let panelSV = scrollView(documentHeight: 400, viewportHeight: 150)
        coordinator.attachPDF(scrollView: pdfSV, model: model)
        coordinator.attachPanel(scrollView: panelSV, model: model)
        coordinator.segments = [AlignmentSegment(id: "b1", pdfStart: 0, pdfHeight: 1000, panelStart: 0, panelHeight: 400)]

        DocumentSpace.scroll(pdfSV, topDownTop: 300) // simulates a real user scroll on the PDF
        try await pump()

        // The panel must have moved, driven by the PDF.
        #expect(DocumentSpace.visibleTopDown(panelSV)?.top != 0)
        let pdfTopAfterDrive = DocumentSpace.visibleTopDown(pdfSV)?.top

        try await pump() // let the echo of the panel's movement settle
        // No bounce-back: the PDF did not move again.
        #expect(DocumentSpace.visibleTopDown(pdfSV)?.top == pdfTopAfterDrive)
    }

    @Test("with 'Follow the PDF' off the two sides stay independent")
    func independentWhenFollowIsOff() async throws {
        let model = try makeModel()
        model.followPDF = false
        let coordinator = model.syncCoordinator
        let pdfSV = scrollView(documentHeight: 1000, viewportHeight: 300)
        let panelSV = scrollView(documentHeight: 400, viewportHeight: 150)
        coordinator.attachPDF(scrollView: pdfSV, model: model)
        coordinator.attachPanel(scrollView: panelSV, model: model)
        coordinator.segments = [AlignmentSegment(id: "b1", pdfStart: 0, pdfHeight: 1000, panelStart: 0, panelHeight: 400)]

        DocumentSpace.scroll(pdfSV, topDownTop: 300)
        try await pump()

        #expect(DocumentSpace.visibleTopDown(panelSV)?.top == 0)
    }

    @Test("clicking a mark in the PDF scrolls the panel to the card that contains it")
    func pdfMarkClickScrollsPanel() async throws {
        let model = try makeModel()
        let coordinator = model.syncCoordinator
        let pdfSV = scrollView(documentHeight: 1000, viewportHeight: 300)
        let panelSV = scrollView(documentHeight: 400, viewportHeight: 150)
        coordinator.attachPDF(scrollView: pdfSV, model: model)
        coordinator.attachPanel(scrollView: panelSV, model: model)
        coordinator.segments = [
            AlignmentSegment(id: "b-b1", pdfStart: 0, pdfHeight: 200, panelStart: 0, panelHeight: 100),
            AlignmentSegment(id: "b-b2", pdfStart: 200, pdfHeight: 200, panelStart: 100, panelHeight: 100),
        ]

        var analysis = AnalysisRecord()
        let mark = Mark(id: "m1", termId: "t1", type: .rectangle, text: "FDA", source: .claude, page: 1, range: MarkRange(start: 0, length: 3))
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, marks: [mark])
        model.analysisController.updateContext(fingerprint: "fp", documentTitle: "T", blocks: [block("b1", page: 0), block("b2", page: 1)], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])

        coordinator.handlePDFMarkClicked(termId: "t1", markId: "m1")
        try await pump()

        // Segment "b-b2": panelStart=100, reading line=150*0.3=45 → 100-45=55.
        #expect(DocumentSpace.visibleTopDown(panelSV)?.top == 55)
    }

    @Test("navigation from the chat or the concept map makes the panel follow to the page")
    func externalPageNavigationScrollsPanel() async throws {
        let model = try makeModel()
        let coordinator = model.syncCoordinator
        let panelSV = scrollView(documentHeight: 500, viewportHeight: 150)
        coordinator.attachPanel(scrollView: panelSV, model: model)
        coordinator.segments = [
            AlignmentSegment(id: "b-b1", pdfStart: 0, pdfHeight: 300, panelStart: 0, panelHeight: 150),
            AlignmentSegment(id: "b-b2", pdfStart: 300, pdfHeight: 300, panelStart: 180, panelHeight: 150),
        ]

        coordinator.handlePDFPositionNavigation(topDownY: 320)
        try await pump()

        // Second segment: 180 - reading line 45 = 135.
        #expect(DocumentSpace.visibleTopDown(panelSV)?.top == 135)
    }

    @Test("clicking a repetition (no markId): goes to the first block that marks that term")
    func repetitionClickUsesFirstBlock() async throws {
        let model = try makeModel()
        let coordinator = model.syncCoordinator
        let pdfSV = scrollView(documentHeight: 1000, viewportHeight: 300)
        let panelSV = scrollView(documentHeight: 400, viewportHeight: 150)
        coordinator.attachPDF(scrollView: pdfSV, model: model)
        coordinator.attachPanel(scrollView: panelSV, model: model)
        coordinator.segments = [
            AlignmentSegment(id: "b-b1", pdfStart: 0, pdfHeight: 200, panelStart: 0, panelHeight: 100),
            AlignmentSegment(id: "b-b2", pdfStart: 200, pdfHeight: 200, panelStart: 100, panelHeight: 100),
        ]

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [Mark(id: "m1", termId: "t1", type: .rectangle, text: "FDA", source: .claude, page: 0, range: MarkRange(start: 0, length: 3))])
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, marks: [Mark(id: "m2", termId: "t1", type: .rectangle, text: "FDA", source: .claude, page: 1, range: MarkRange(start: 0, length: 3))])
        model.analysisController.updateContext(fingerprint: "fp", documentTitle: "T", blocks: [block("b1", page: 0), block("b2", page: 1)], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])

        coordinator.handlePDFMarkClicked(termId: "t1", markId: nil) // repetition: no markId of its own
        try await pump()

        // Segment "b-b1" (the first one), not "b-b2": panelStart=0 → 0-45 → clamped to 0.
        #expect(DocumentSpace.visibleTopDown(panelSV)?.top == 0)
    }

    @Test("a guarded jump (`performGuardedNavigation`) does not trigger automatic synchronization (no jump/bounce when clicking a heading in the contents)")
    func guardedNavigationDoesNotTriggerDrive() async throws {
        let model = try makeModel()
        model.followPDF = true
        let coordinator = model.syncCoordinator
        let pdfSV = scrollView(documentHeight: 1000, viewportHeight: 300)
        let panelSV = scrollView(documentHeight: 400, viewportHeight: 150)
        coordinator.attachPDF(scrollView: pdfSV, model: model)
        coordinator.attachPanel(scrollView: panelSV, model: model)
        coordinator.segments = [AlignmentSegment(id: "b1", pdfStart: 0, pdfHeight: 1000, panelStart: 0, panelHeight: 400)]

        // A direct jump (like `DocumentModel.goToTocEntry`, a single
        // navigation call) wrapped in the guard: unlike a real user scroll,
        // it must not move the panel, neither immediately nor after AppKit's
        // re-entrant notifications have settled (no two-step bounce/jump).
        coordinator.performGuardedNavigation {
            DocumentSpace.scroll(pdfSV, topDownTop: 300)
        }
        try await pump()
        #expect(DocumentSpace.visibleTopDown(panelSV)?.top == 0)
        try await pump()
        #expect(DocumentSpace.visibleTopDown(panelSV)?.top == 0)

        // The PDF itself did arrive where requested: the guard only
        // suppresses automatic synchronization, not the scrolling.
        #expect(DocumentSpace.visibleTopDown(pdfSV)?.top == 300)
    }

    @Test("clicking a term in the panel scrolls the PDF to the first real mark")
    func panelTermClickScrollsPDF() async throws {
        let model = try makeModel()
        let coordinator = model.syncCoordinator
        let pdfSV = scrollView(documentHeight: 1000, viewportHeight: 300)
        let panelSV = scrollView(documentHeight: 400, viewportHeight: 150)
        coordinator.attachPDF(scrollView: pdfSV, model: model)
        coordinator.attachPanel(scrollView: panelSV, model: model)
        coordinator.segments = [
            AlignmentSegment(id: "b-b1", pdfStart: 0, pdfHeight: 400, panelStart: 0, panelHeight: 100),
            AlignmentSegment(id: "b-b2", pdfStart: 400, pdfHeight: 400, panelStart: 100, panelHeight: 100),
        ]

        var analysis = AnalysisRecord()
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, marks: [Mark(id: "m1", termId: "t1", type: .rectangle, text: "FDA", source: .claude, page: 1, range: MarkRange(start: 0, length: 3))])
        model.analysisController.updateContext(fingerprint: "fp", documentTitle: "T", blocks: [block("b1", page: 0), block("b2", page: 1)], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])

        coordinator.handlePanelTermClicked(termId: "t1")
        try await pump()

        // Segment "b-b2": pdfStart=400, reading line=300*0.3=90 → 400-90=310.
        #expect(DocumentSpace.visibleTopDown(pdfSV)?.top == 310)
    }
}
}
