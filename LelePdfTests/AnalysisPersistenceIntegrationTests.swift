import Foundation
import Testing
@testable import LelePdf

/// Integration: a complete analysis (post-processing + `AnalysisPersistence
/// .save`) saved in a real `DocumentStore` on a
/// temporary folder, reloaded from a new actor (as when the app is
/// reopened) and also verified in the Markdown exported by the existing
/// Store (M3, not touched here).
@Suite("AnalysisPersistence · integration")
struct AnalysisPersistenceIntegrationTests {
    private func tempDataFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfAnalysisPersistenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("analysis saved, read back by a new actor, progress and Markdown correct")
    func fullRoundTripWithProgressAndMarkdown() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fingerprint = "fp-persistence"
        let store = DocumentStore(dataFolderURL: dir)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "doc.pdf", lastKnownPath: "/tmp/doc.pdf", title: "Documento", pageCount: 1)
        let blockRecord = BlockRecord(id: "b1", sectionPath: ["Capitolo 1"], pageStart: 0, pageEnd: 0, textHash: "hash-b1", words: 10)
        _ = await store.updateStructure(fingerprint: fingerprint, toc: TocRecord(source: .native, entries: []), segmentationVersion: 1, blocks: [blockRecord], exhibits: [])

        let cleanText = "Il Farmaco X ha ridotto i costi."
        let block = TextBlock(
            id: "b1", sectionPath: ["Capitolo 1"], pageStart: 0, pageEnd: 0, cleanText: cleanText,
            textHash: "hash-b1", words: 7,
            spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: cleanText.count, charMap: Array(0 ..< cleanText.count))],
            lineRectsByPage: [:]
        )
        let response = AnalysisResponseRaw(
            title: "Riduzione dei costi",
            rewrite: [RewriteItem(kind: .summary, text: "{{m1|Farmaco X}} ha ridotto i costi.")],
            marks: [AnalysisMarkRaw(id: "m1", text: "Farmaco X", mark: .rectangle, term: "Farmaco X", termId: nil)],
            links: []
        )
        let output = AnalysisPostProcessor.process(.init(response: response, block: block, existingTerms: [:]))
        #expect(output.marks.count == 1)

        _ = await AnalysisPersistence.save(store: store, fingerprint: fingerprint, blockId: "b1", output: output, model: "sonnet", updateProgress: true)
        await store.flush(fingerprint: fingerprint)

        // Simulates reopening: a new actor on the same folder.
        let reopened = DocumentStore(dataFolderURL: dir)
        let loaded = try #require(await reopened.loadRecordAndAnalysis(fingerprint: fingerprint))

        #expect(loaded.record.progress.analyzedBlockIds == ["b1"])
        #expect(loaded.record.progress.lastAnalyzedBlockId == "b1")
        let savedBlock = try #require(loaded.analysis.blocks["b1"])
        #expect(savedBlock.status == .analyzed)
        #expect(savedBlock.marks.first?.text == "Farmaco X")
        #expect(loaded.analysis.terms.count == 1)
        // The snapshot of Claude's marks goes to disk and comes back identical
        // after a reopen (read back by a new actor).
        #expect(savedBlock.claudeMarks == output.marks)
        #expect(savedBlock.claudeLinks == output.links)

        let markdown = MarkdownExporter.render(document: loaded.record, analysis: loaded.analysis)
        #expect(markdown.contains("==Farmaco X=="))
    }
}
