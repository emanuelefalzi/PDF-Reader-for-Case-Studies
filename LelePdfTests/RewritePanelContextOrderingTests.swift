import Foundation
import Testing
@testable import LelePdf

/// Investigation into the right panel being empty at times (hypothesis: saved
/// analyses not reattached/published on reopening, a race between the Store
/// load, the pipeline structure and `documentOrderSegments()`).
/// `DocumentModel` publishes the analysis context twice on opening, in an
/// order not guaranteed with respect to which arrives first
/// (`App/DocumentModel.swift`): the Store's fast path (`performFastLookup`,
/// nearly immediate) with `structure?.blocks ?? []`, so with the blocks still
/// empty the first time, and then the pipeline (`attachStructureToStore`,
/// slower) with the real blocks. These tests exercise
/// `AnalysisController.updateContext` directly (the same level used by
/// `DocumentModel.refreshAnalysisContext`, with no need for
/// `DocumentModel`/`AppStore.shared`/PDFKit) in every possible order: after
/// the LAST update with the right data, rows and cards must always be
/// populated. If one of these failed, `updateContext`/`context` (not the UI)
/// would be the cause of the empty panel.
@Suite("RewritePanel · context arrival order (Store/Structure/Analysis)")
struct RewritePanelContextOrderingTests {
    private func tempStore() throws -> (store: DocumentStore, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfContextOrderingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DocumentStore(dataFolderURL: dir), { try? FileManager.default.removeItem(at: dir) })
    }

    private func block(_ id: String, page: Int, text: String = "Testo di prova per il blocco.") -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id, words: 5, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    /// A plausible "already saved" analysis: an analyzed block with a real
    /// summary, as it would be found in `analisi.json` when reopening a
    /// document that has already been worked on.
    private func savedAnalysis(blockId: String) -> AnalysisRecord {
        var analysis = AnalysisRecord()
        analysis.blocks[blockId] = BlockAnalysis(
            status: .analyzed, title: "Titolo salvato",
            rewrite: [RewriteItem(kind: .summary, text: "Riassunto già analizzato in una sessione precedente.")]
        )
        return analysis
    }

    @MainActor
    private func makeController(store: DocumentStore) -> AnalysisController {
        AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!)
    }

    @MainActor
    @Test("Store first (empty blocks, analysis already present), then the structure arrives: rows and card appear")
    func storeFirstThenStructure() throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let controller = makeController(store: store)
        let analysis = savedAnalysis(blockId: "b1")

        // 1) The Store's fast path: structure not yet known (like
        // `DocumentModel.performFastLookup` before the pipeline finishes).
        controller.updateContext(fingerprint: "fp", documentTitle: "T", blocks: [], exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b1", tocEntries: [])
        #expect(controller.documentOrderSegments().isEmpty, "without blocks there are no rows to show yet (expected, transient)")
        #expect(controller.cardData(for: "b1") == nil)

        // 2) The pipeline finishes: the real structure is published together
        // with the analysis (like `attachStructureToStore`/`refreshAnalysisContext`).
        controller.updateContext(fingerprint: "fp", documentTitle: "T", blocks: [block("b1", page: 0)], exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b1", tocEntries: [])
        let segments = controller.documentOrderSegments()
        #expect(segments == [.block(blockId: "b1")], "after the structure arrives the block's row must appear")
        #expect(controller.cardData(for: "b1")?.title == "Titolo salvato")
    }

    @MainActor
    @Test("structure first (no analysis), then the analysis arrives after the first render: the card appears")
    func structureFirstThenAnalysis() throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let controller = makeController(store: store)

        // 1) Structure ready but analysis still empty (like right after
        // `attachStructureToStore` the very first time, for a document never
        // opened before: no existing analisi.json).
        controller.updateContext(fingerprint: "fp", documentTitle: "T", blocks: [block("b1", page: 0)], exhibits: [], analysis: AnalysisRecord(), lastAnalyzedBlockId: nil, tocEntries: [])
        #expect(controller.documentOrderSegments() == [.block(blockId: "b1")], "the row already exists (placeholder), just without a card")
        #expect(controller.cardData(for: "b1") == nil, "no card until the block is analyzed")

        // 2) The analysis arrives later (e.g. `applyStoreResult` from a second
        // Store pass, or after `markBlockAnalyzed`).
        let analysis = savedAnalysis(blockId: "b1")
        controller.updateContext(fingerprint: "fp", documentTitle: "T", blocks: [block("b1", page: 0)], exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b1", tocEntries: [])
        #expect(controller.cardData(for: "b1")?.title == "Titolo salvato")
    }

    @MainActor
    @Test("everything together from the start (common case, no race): rows and card already correct on the first updateContext")
    func everythingTogetherFromStart() throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let controller = makeController(store: store)
        let analysis = savedAnalysis(blockId: "b1")

        controller.updateContext(fingerprint: "fp", documentTitle: "T", blocks: [block("b1", page: 0)], exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b1", tocEntries: [])
        #expect(controller.documentOrderSegments() == [.block(blockId: "b1")])
        #expect(controller.cardData(for: "b1")?.title == "Titolo salvato")
    }
}
