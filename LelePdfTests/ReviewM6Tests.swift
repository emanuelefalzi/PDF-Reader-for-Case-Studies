import AppKit
import Foundation
import Testing
@testable import LelePdf

/// Additional tests from the Codex cross-review of M6.
@MainActor
@Suite("Review M6 · Codex cross-review", .serialized)
struct ReviewM6Tests {
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private func scrollView(documentHeight: CGFloat, viewportHeight: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: viewportHeight))
        scroll.documentView = FlippedDocumentView(
            frame: CGRect(x: 0, y: 0, width: 300, height: documentHeight)
        )
        scroll.contentView.setFrameSize(NSSize(width: 300, height: viewportHeight))
        return scroll
    }

    private func model() throws -> DocumentModel {
        let url = try StoreFixtures.makeTextPDF(
            text: "Documento temporaneo per la review M6.",
            fileName: "review-m6-\(UUID()).pdf"
        )
        let data = try Data(contentsOf: url)
        return try #require(DocumentModel(
            document: PDFFileDocument(data: data, displayName: "review-m6"),
            fileURL: url
        ))
    }

    private func block(_ id: String, page: Int) -> TextBlock {
        TextBlock(
            id: id,
            sectionPath: [],
            pageStart: page,
            pageEnd: page,
            cleanText: "Termine",
            textHash: id,
            words: 1,
            spans: [],
            lineRectsByPage: [:]
        )
    }

    @Test("the measurement detects the clamp offset even within the same segment")
    func offsetMeasurementDoesNotHideClampError() {
        let segments = [AlignmentSegment(
            id: "b1",
            pdfStart: 0,
            pdfHeight: 1_000,
            panelStart: 0,
            panelHeight: 1_000
        )]
        let lookup = AlignmentModel.Lookup(index: 0, fraction: 0.9)
        // Expected point 900; the clamp leaves the top at 700 and the line at 790.
        let offset = AlignmentModel.offsetAfterApplying(
            lookup,
            segments: segments,
            targetSide: .panel,
            appliedTop: 700,
            readingLineOffset: 90
        )
        #expect(offset == 110)
    }

    @Test("the markId survives resolution and allows an exact hover")
    func markIdentitySurvivesRewritePipeline() {
        let built = MarkedTextBuilder.build([
            .marked(text: "termine", markId: "m-esatto", termId: "t1", type: .rectangle),
        ])
        #expect(built.marks.first?.markId == "m-esatto")
        #expect(HoverLinking.state(
            markId: "m-esatto", blockId: "b1", termId: "t1", isRepetition: false,
            hoveredMarkId: "m-esatto", hoveredBlockId: "b1", hoveredTermId: "t1"
        ) == .hover)
        // A DIFFERENT markId in the same block is never the target.
        #expect(HoverLinking.state(
            markId: "m-altro", blockId: "b1", termId: "t1", isRepetition: false,
            hoveredMarkId: "m-esatto", hoveredBlockId: "b1", hoveredTermId: "t1"
        ) == .normal)
    }

    @Test("a repetition links to the markId of the first block")
    func repetitionLinksFirstBlockMark() throws {
        let model = try model()
        var analysis = AnalysisRecord()
        analysis.terms["t1"] = TermRecord(term: "Termine", type: .rectangle, firstBlockId: "b1")
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed,
            marks: [Mark(
                id: "m1",
                termId: "t1",
                type: .rectangle,
                text: "Termine",
                source: .claude,
                page: 0,
                range: MarkRange(start: 0, length: 7)
            )]
        )
        model.analysisController.updateContext(
            fingerprint: "fp",
            documentTitle: "T",
            blocks: [block("b1", page: 0), block("b2", page: 1)],
            exhibits: [],
            analysis: analysis,
            lastAnalyzedBlockId: nil,
            tocEntries: []
        )
        #expect(model.analysisController.firstVisibleMarkId(for: "t1") == "m1")
    }

    @Test("detach followed by reattach on the same pair restores the observers")
    func detachAndReattachRestoresSynchronization() async throws {
        let model = try model()
        model.followPDF = true
        let pdf = scrollView(documentHeight: 1_000, viewportHeight: 300)
        let panel = scrollView(documentHeight: 400, viewportHeight: 150)
        let coordinator = model.syncCoordinator
        coordinator.attachPDF(scrollView: pdf, model: model)
        coordinator.attachPanel(scrollView: panel, model: model)
        coordinator.detach()
        coordinator.attachPDF(scrollView: pdf, model: model)
        coordinator.attachPanel(scrollView: panel, model: model)
        coordinator.segments = [AlignmentSegment(
            id: "b1",
            pdfStart: 0,
            pdfHeight: 1_000,
            panelStart: 0,
            panelHeight: 400
        )]

        DocumentSpace.scroll(pdf, topDownTop: 300)
        try await Task.sleep(for: .milliseconds(50))
        #expect(DocumentSpace.visibleTopDown(panel)?.top == 111)
    }

    @Test("a click in the panel uses the exact markId, not the first term with the same name")
    func panelClickUsesExactMark() throws {
        let model = try model()
        let pdf = scrollView(documentHeight: 1_000, viewportHeight: 300)
        let panel = scrollView(documentHeight: 400, viewportHeight: 150)
        let coordinator = model.syncCoordinator
        coordinator.attachPDF(scrollView: pdf, model: model)
        coordinator.attachPanel(scrollView: panel, model: model)
        coordinator.segments = [
            AlignmentSegment(id: "b-b1", pdfStart: 100, pdfHeight: 200, panelStart: 0, panelHeight: 100),
            AlignmentSegment(id: "b-b2", pdfStart: 500, pdfHeight: 200, panelStart: 100, panelHeight: 100),
        ]

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [
            Mark(id: "m1", termId: "t1", type: .rectangle, text: "Termine", source: .claude, page: 0, range: MarkRange(start: 0, length: 7)),
        ])
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, marks: [
            Mark(id: "m2", termId: "t1", type: .rectangle, text: "Termine", source: .claude, page: 1, range: MarkRange(start: 0, length: 7)),
        ])
        model.analysisController.updateContext(
            fingerprint: "fp",
            documentTitle: "T",
            blocks: [block("b1", page: 0), block("b2", page: 1)],
            exhibits: [],
            analysis: analysis,
            lastAnalyzedBlockId: nil,
            tocEntries: []
        )

        coordinator.handlePanelTermClicked(termId: "t1", markId: "m2")
        #expect(DocumentSpace.visibleTopDown(pdf)?.top == 410)
    }

    @Test("an unknown markId (mark removed/reattachment missed) falls back to the first block that marks the term, instead of not scrolling")
    func panelClickFallsBackWhenMarkIdIsStale() throws {
        let model = try model()
        let pdf = scrollView(documentHeight: 1_000, viewportHeight: 300)
        let panel = scrollView(documentHeight: 400, viewportHeight: 150)
        let coordinator = model.syncCoordinator
        coordinator.attachPDF(scrollView: pdf, model: model)
        coordinator.attachPanel(scrollView: panel, model: model)
        coordinator.segments = [
            AlignmentSegment(id: "b-b1", pdfStart: 100, pdfHeight: 200, panelStart: 0, panelHeight: 100),
            AlignmentSegment(id: "b-b2", pdfStart: 500, pdfHeight: 200, panelStart: 100, panelHeight: 100),
        ]

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [
            Mark(id: "m1", termId: "t1", type: .rectangle, text: "Termine", source: .claude, page: 0, range: MarkRange(start: 0, length: 7)),
        ])
        model.analysisController.updateContext(
            fingerprint: "fp",
            documentTitle: "T",
            blocks: [block("b1", page: 0), block("b2", page: 1)],
            exhibits: [],
            analysis: analysis,
            lastAnalyzedBlockId: nil,
            tocEntries: []
        )

        // "m-fantasma" (phantom) does not exist in any block: fall back to the termId alone (b1).
        coordinator.handlePanelTermClicked(termId: "t1", markId: "m-fantasma")
        #expect(DocumentSpace.visibleTopDown(pdf)?.top == 10)
    }

    @Test("HoverLinking: no match returns the base state (normal or repetition)")
    func hoverLinkingDefaultsWithoutMatch() {
        #expect(HoverLinking.state(markId: "m1", blockId: "b1", termId: "t1", isRepetition: false, hoveredMarkId: nil, hoveredBlockId: nil, hoveredTermId: nil) == .normal)
        #expect(HoverLinking.state(markId: nil, blockId: nil, termId: "t1", isRepetition: true, hoveredMarkId: nil, hoveredBlockId: nil, hoveredTermId: nil) == .repetition)
        #expect(HoverLinking.state(markId: "m1", blockId: "b1", termId: "t1", isRepetition: false, hoveredMarkId: "m-altro", hoveredBlockId: "b9", hoveredTermId: "t-altro") == .normal)
    }

    @Test("HoverLinking: hover from a map node (termId only, no markId) lights up every real mark of the term")
    func hoverLinkingTermOnlyIsMapBroadcast() {
        // The `MapSidebarView`/`MapExpandedView` case (SPEC §5.3 "the
        // corresponding marks light up", plural): a node represents the
        // concept, not a specific mark, so aggregating by termId is intended
        // here.
        #expect(HoverLinking.state(markId: "m2", blockId: "b2", termId: "t1", isRepetition: false, hoveredMarkId: nil, hoveredBlockId: nil, hoveredTermId: "t1") == .hover)
    }

    @Test("hover word by word on a mark does NOT light up another mark with the same local id in a different block")
    func hoverDoesNotCrossBlocksWithSameLocalMarkId() {
        // `{{mX|...}}` restarts from m1 in every block (local numbering):
        // "m1" of block b1 and "m1" of block b7 are not the same mark. Before
        // the fix, `HoverLinking.state` compared only `markId`, without
        // `blockId`: hovering mark "m1" of b1 would also have lit up "m1" of
        // b7 (the reported "many more get highlighted" bug).
        let hoveredInB1 = HoverLinking.state(
            markId: "m1", blockId: "b1", termId: "concetto-a", isRepetition: false,
            hoveredMarkId: "m1", hoveredBlockId: "b1", hoveredTermId: "concetto-a"
        )
        let unrelatedInB7 = HoverLinking.state(
            markId: "m1", blockId: "b7", termId: "concetto-b", isRepetition: false,
            hoveredMarkId: "m1", hoveredBlockId: "b1", hoveredTermId: "concetto-a"
        )
        #expect(hoveredInB1 == .hover)
        #expect(unrelatedInB7 == .normal)
    }

    @Test("hover on a real mark does not light up ANOTHER real mark of the same termId in a different block")
    func hoverDoesNotLightUpOtherRealMarksOfSameTermInDifferentBlocks() {
        // A termId can have independent REAL marks in several blocks (not
        // just textual repetitions, `Repetitions.swift`): Claude can mark
        // "Nintendo" as a concept in its own right in both block 3.2 and
        // block 7.1. Hovering one must not light up the other, only the
        // "counterpart on the other side" of the SAME mark (SPEC §5.8).
        let ownMark = HoverLinking.state(
            markId: "m3", blockId: "b-3-2", termId: "nintendo", isRepetition: false,
            hoveredMarkId: "m3", hoveredBlockId: "b-3-2", hoveredTermId: "nintendo"
        )
        let sameTermOtherBlock = HoverLinking.state(
            markId: "m1", blockId: "b-7-1", termId: "nintendo", isRepetition: false,
            hoveredMarkId: "m3", hoveredBlockId: "b-3-2", hoveredTermId: "nintendo"
        )
        #expect(ownMark == .hover)
        #expect(sameTermOtherBlock == .normal)
    }

    @Test("hover on a repetition does not light up the OTHER repetitions of the same term, only the real mark of the first block")
    func hoverOnRepetitionLightsUpOnlyCanonicalMark() {
        // `MarksOverlayHover` resolves a repetition (with no markId of its
        // own) to the real mark of the first block (`firstVisibleMark`), SPEC
        // §5.8 "for a repetition, the term's mark in its first block": the
        // OTHER repetitions scattered across the document must not light up.
        let canonical = HoverLinking.state(
            markId: "m1", blockId: "b1", termId: "t1", isRepetition: false,
            hoveredMarkId: "m1", hoveredBlockId: "b1", hoveredTermId: "t1"
        )
        let anotherRepetitionElsewhere = HoverLinking.state(
            markId: nil, blockId: nil, termId: "t1", isRepetition: true,
            hoveredMarkId: "m1", hoveredBlockId: "b1", hoveredTermId: "t1"
        )
        #expect(canonical == .hover)
        #expect(anotherRepetitionElsewhere == .repetition)
    }

    @Test("firstVisibleMarkId falls back to the first mark in document order if firstBlockId no longer marks that term")
    func firstVisibleMarkIdFallsBackWhenFirstBlockLacksTheMark() throws {
        let model = try model()
        var analysis = AnalysisRecord()
        // The registry points to "b1", which no longer marks "t1" (e.g. after a
        // targeted regeneration): the fallback must find the mark in "b2".
        analysis.terms["t1"] = TermRecord(term: "Termine", type: .rectangle, firstBlockId: "b1")
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [])
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, marks: [
            Mark(id: "m2", termId: "t1", type: .rectangle, text: "Termine", source: .claude, page: 1, range: MarkRange(start: 0, length: 7)),
        ])
        model.analysisController.updateContext(
            fingerprint: "fp",
            documentTitle: "T",
            blocks: [block("b1", page: 0), block("b2", page: 1)],
            exhibits: [],
            analysis: analysis,
            lastAnalyzedBlockId: nil,
            tocEntries: []
        )
        #expect(model.analysisController.firstVisibleMarkId(for: "t1") == "m2")
    }

    @Test("reattaching the PDF to a different NSScrollView (new document) removes the observer on the old one: it no longer drives, nor duplicates updates")
    func attachingDifferentScrollViewRemovesPreviousObserver() async throws {
        let model = try model()
        model.followPDF = true
        let coordinator = model.syncCoordinator
        let oldPdf = scrollView(documentHeight: 1_000, viewportHeight: 300)
        let newPdf = scrollView(documentHeight: 2_000, viewportHeight: 300)
        let panel = scrollView(documentHeight: 400, viewportHeight: 150)
        coordinator.attachPDF(scrollView: oldPdf, model: model)
        coordinator.attachPanel(scrollView: panel, model: model)
        coordinator.segments = [AlignmentSegment(id: "b1", pdfStart: 0, pdfHeight: 1_000, panelStart: 0, panelHeight: 400)]

        // New document: replaces the scroll view WITHOUT going through
        // `detach()` (as `PDFKitView` would when recreating the view). Without
        // removing the old observer, scrolling `oldPdf` would still read
        // `pdfScrollView` (already the new one) instead of staying silent.
        coordinator.attachPDF(scrollView: newPdf, model: model)

        DocumentSpace.scroll(oldPdf, topDownTop: 300)
        try await Task.sleep(for: .milliseconds(50))
        #expect(DocumentSpace.visibleTopDown(panel)?.top == 0, "the old NSScrollView must no longer drive the synchronization")

        DocumentSpace.scroll(newPdf, topDownTop: 300)
        try await Task.sleep(for: .milliseconds(50))
        #expect(DocumentSpace.visibleTopDown(panel)?.top == 111, "the new NSScrollView must drive normally")
    }
}
