import AppKit
import Foundation
import Testing
@testable import LelePdf

/// The AppKit/persistence part of `ReviewM7Tests.swift`, in a separate file
/// to keep files under ~12 KB.
@MainActor
@Suite("Review M7 · AppKit and persistence", .serialized)
struct ReviewM7IntegrationTests {
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LelePdf-ReviewM7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func textBlock(_ id: String, text: String) -> TextBlock {
        TextBlock(
            id: id, sectionPath: [], pageStart: 0, pageEnd: 0,
            cleanText: text, textHash: id, words: 3,
            spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
            lineRectsByPage: [:]
        )
    }

    private func documentModel() throws -> DocumentModel {
        let url = try StoreFixtures.makeTextPDF(
            text: "Documento di prova per segni con id locali al blocco.",
            fileName: "review-m7-\(UUID().uuidString).pdf"
        )
        let file = PDFFileDocument(data: try Data(contentsOf: url), displayName: "review-m7")
        return try #require(DocumentModel(document: file, fileURL: url))
    }

    @Test("NSTextView correctly converts Character spans with long UTF-16 graphemes")
    func editableTextViewUnicodeRoundTrip() {
        let view = EditableMarkedNSTextView()
        let span = RewriteEditText.MarkSpan(range: NSRange(location: 2, length: 5), markId: "m1")
        view.setInitialContent(text: "😀 tasso", spans: [span])
        let content = view.currentContent()
        #expect(content.text == "😀 tasso")
        #expect(content.spans == [span])
    }

    @Test("an edit does not delete PDF marks that were not represented in the editor")
    func editPreservesNonEditableMarks() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DocumentStore(dataFolderURL: folder)
        _ = await store.registerDocument(fingerprint: "fp-edit", byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let explicit = Mark(id: "m1", termId: "t1", type: .rectangle, text: "alpha", source: .claude, page: 0, range: MarkRange(start: 0, length: 5))
        let computedManual = Mark(id: "m2", termId: "t2", type: .circle, text: "beta", source: .manual, page: 0, range: MarkRange(start: 6, length: 4))
        let pdfOnlyClaude = Mark(id: "m3", termId: "t3", type: .underline, text: "gamma", source: .claude, page: 0, range: MarkRange(start: 11, length: 5))
        let rewrite = [RewriteItem(kind: .paragraph, text: "{{m1|alpha}} modificabile")]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, rewrite: rewrite, claudeRewrite: rewrite, marks: [explicit, computedManual, pdfOnlyClaude])
        let controller = AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-review-m7-\(UUID())")!)
        controller.updateContext(fingerprint: "fp-edit", documentTitle: "A", blocks: [textBlock("b1", text: "alpha beta gamma")], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])

        await controller.saveManualEdit(
            blockId: "b1", editedText: "alpha modificato",
            editedSpans: [RewriteEditText.MarkSpan(range: NSRange(location: 0, length: 5), markId: "m1")]
        )

        let marks = try #require(controller.context?.analysis.blocks["b1"]?.marks)
        #expect(Set(marks.map(\.id)) == Set(["m1", "m2", "m3"]))
        #expect(marks.allSatisfy { !$0.hidden })
    }

    @Test("manual mark: notifies the map and persists after reopening")
    func manualMarkNotifiesAndPersists() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fingerprint = "fp-roundtrip"
        let store = DocumentStore(dataFolderURL: folder)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let controller = AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-review-m7-\(UUID())")!)
        controller.updateContext(fingerprint: fingerprint, documentTitle: "A", blocks: [textBlock("b1", text: "termine manuale")], exhibits: [], analysis: AnalysisRecord(), lastAnalyzedBlockId: nil, tocEntries: [])
        var notifications = 0
        controller.onAnalysisSavedExternal = { _ in notifications += 1 }

        await controller.addManualMark(blockId: "b1", type: .rectangle, text: "termine", page: 0, cleanRange: NSRange(location: 0, length: 7))
        #expect(notifications == 1)
        await store.flush(fingerprint: fingerprint)

        let reopened = DocumentStore(dataFolderURL: folder)
        let loaded = try #require(await reopened.loadRecordAndAnalysis(fingerprint: fingerprint))
        let mark = try #require(loaded.analysis.blocks["b1"]?.marks.first)
        #expect(mark.source == .manual)
        #expect(mark.text == "termine")
        #expect(mark.hidden == false)
    }

    @Test("identical mark ids in different blocks: a PDF click uses the owning block")
    func duplicateMarkIDsUseOwningBlock() throws {
        let model = try documentModel()
        let pdf = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 150))
        pdf.documentView = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        pdf.contentView.setFrameSize(NSSize(width: 300, height: 150))
        let panel = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 150))
        panel.documentView = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        panel.contentView.setFrameSize(NSSize(width: 300, height: 150))
        model.syncCoordinator.attachPDF(scrollView: pdf, model: model)
        model.syncCoordinator.attachPanel(scrollView: panel, model: model)
        model.syncCoordinator.segments = [
            AlignmentSegment(id: "b-b1", pdfStart: 0, pdfHeight: 100, panelStart: 0, panelHeight: 100),
            AlignmentSegment(id: "b-b2", pdfStart: 100, pdfHeight: 100, panelStart: 240, panelHeight: 100),
        ]
        let duplicatedID = "m1"
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [
            Mark(id: duplicatedID, termId: "t1", type: .rectangle, text: "uno", source: .claude, page: 0, range: MarkRange(start: 0, length: 1)),
        ])
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, marks: [
            Mark(id: duplicatedID, termId: "t2", type: .circle, text: "due", source: .claude, page: 0, range: MarkRange(start: 0, length: 1)),
        ])
        model.analysisController.updateContext(
            fingerprint: "fp-duplicate", documentTitle: "A",
            blocks: [textBlock("b1", text: "uno"), textBlock("b2", text: "due")],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )

        model.syncCoordinator.handlePDFMarkClicked(termId: "t2", markId: duplicatedID, blockId: "b2")
        #expect(DocumentSpace.visibleTopDown(panel)?.top == 195)
        model.syncCoordinator.handlePanelTermClicked(termId: "t2", markId: duplicatedID, blockId: "b2")
        #expect(DocumentSpace.visibleTopDown(pdf)?.top == 55)
        model.syncCoordinator.detach()
    }
}
