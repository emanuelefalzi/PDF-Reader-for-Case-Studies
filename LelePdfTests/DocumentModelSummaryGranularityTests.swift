import Testing
import Foundation
@testable import LelePdf

/// Real `DocumentModel` ↔ `AppStore.shared` integration. The individual rules
/// (segmentation, re-attachment, persistence) are already tested separately
/// (`BlockSegmenterGranularityTests`, `SummaryGranularityStoreTests`); here we
/// verify that `DocumentModel.applySummaryGranularity`/`previewOrphanCount`
/// really wire `structure`/`documentRecord`/`analysisController` together the
/// same way as `attachStructureToStore` (SPEC §6.2/§8), INCLUDING the
/// automatic, silent recomputation that `attachStructureToStore` performs on
/// its own for a new document (it immediately receives the Settings default,
/// `.heading3` in this suite -- `recomputeBlocksForChosenGranularityIfNeeded`).
///
/// `.serialized` (like `DocumentModelStoreIntegrationTests`): `AppStore.shared`
/// is a singleton shared by the whole suite -- each test uses its own
/// `fingerprint` (UUID) so it does not read state left behind by another test.
@Suite("Summary granularity · DocumentModel + Store", .serialized)
@MainActor
struct DocumentModelSummaryGranularityTests {
    /// Registers the document in the Store FOR REAL, as `PipelineRunner.run`
    /// would in production (`attachStructureToStore`, not `private` -- see
    /// `DocumentModel.swift`), but with a SYNTHETIC structure (no real PDFKit
    /// extraction, same principle as `PerfBenchDocument.build`): two
    /// paragraphs (one per page), a single top-level entry at p.0. With a
    /// single boundary, `.heading3`/`.heading2`/`.chapter` all produce the
    /// SAME single block in this structure (the only entry present is already
    /// level 1); only `.paragraph` (which ignores the contents) yields two.
    /// This is chosen on purpose to isolate "ignores the contents" from
    /// "which threshold level", already covered separately by
    /// `BlockSegmenterGranularityTests`. No candidates for the contents
    /// (`tocCandidates: []`): `maybeGenerateToc` does not start, so there is
    /// no extra fake CLI call in this test. Waits until the automatic
    /// recomputation of the default granularity has FINISHED
    /// (`documentRecord.blocks` populated), not just until `storeFingerprint`
    /// is known.
    private func makeReadyModel(pageCount: Int = 2) async throws -> (model: DocumentModel, cleanup: URL) {
        let sourceURL = try StoreFixtures.makeMultiPageTextPDF(pageCount: pageCount, fileName: "f8-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "f8-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        // Different prefix per page (not the same "word0 word1 …" text
        // repeated identically): otherwise the clean text of a fine-grained
        // block and the START of the merged coarse-grained block share the
        // same first 60 characters on the same `pageStart`, and the block's
        // stable id (SPEC §7.3: section + first 60 characters + start page)
        // COINCIDES by construction. That would be a genuine re-attachment by
        // id, not a false positive, but it would blind this test to what it
        // wants to verify (`usePositionalFallback: false`).
        let paragraphs = (0 ..< pageCount).map { page in PipelineFixtures.paragraph(page: page, text: PipelineFixtures.words(30, prefix: "p\(page)word")) }
        model.tocEntries = [TocEntry(id: "t1", title: "Chapter 1", level: 1, page: 0)]
        model.tocSource = .native
        let structure = DocumentStructure(
            fingerprint: "fp-f8-\(UUID().uuidString)", pageCount: pageCount, headings: [], tocCandidates: [],
            exhibits: [], blocks: BlockSegmenter.segment(paragraphs: paragraphs), textlessPages: false,
            removedHeaderFooterLines: [:], paragraphs: paragraphs
        )
        // `PipelineRunner.run` always does this, in this order, before
        // calling `attachStructureToStore` (which does not touch `structure`
        // by itself).
        model.structure = structure
        model.pipelineState = .ready
        model.attachStructureToStore(structure)

        for _ in 0 ..< 100 where model.documentRecord?.blocks.isEmpty ?? true {
            try await Task.sleep(for: .milliseconds(50))
        }
        // `attachStructureToStore` chains a SECOND `Task` for the automatic
        // recomputation of the default granularity
        // (`recomputeBlocksForChosenGranularityIfNeeded`): the first
        // non-empty `documentRecord.blocks` may still be the one from the
        // current (legacy) segmentation, not yet the chosen granularity --
        // a short fixed margin lets that second pass finish too (local
        // in-memory/JSON work only, no network).
        try await Task.sleep(for: .milliseconds(300))
        _ = try #require(model.storeFingerprint)
        #expect(!(model.documentRecord?.blocks.isEmpty ?? true))
        return (model, sourceURL.deletingLastPathComponent())
    }

    @Test("a new document immediately gets the default granularity and the automatic block recomputation")
    func newDocumentGetsDefaultGranularityAndBlocksAutomatically() async throws {
        let (model, cleanupDir) = try await makeReadyModel()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }

        #expect(model.hasChosenSummaryGranularity)
        #expect(model.effectiveSummaryGranularity == .heading3)
        // A single boundary (the top-level entry) in the synthetic structure:
        // both paragraphs already end up in the same block at the default.
        #expect(model.structure?.blocks.count == 1)
        #expect(model.documentRecord?.blocks.count == 1)
        #expect(model.analysisController.context?.blocks.count == 1)
    }

    @Test("applySummaryGranularity: updates structure.blocks, documentRecord and the analysis context")
    func applyGranularityUpdatesStructureRecordAndContext() async throws {
        let (model, cleanupDir) = try await makeReadyModel()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }

        await model.applySummaryGranularity(.paragraph)

        #expect(model.effectiveSummaryGranularity == .paragraph)
        #expect(model.structure?.blocks.count == 2)
        #expect(model.documentRecord?.blocks.count == 2)
        #expect(model.documentRecord?.summaryGranularity == .paragraph)
        #expect(model.analysisController.context?.blocks.count == 2)

        await model.applySummaryGranularity(.chapter)
        #expect(model.structure?.blocks.count == 1)
        #expect(model.documentRecord?.blocks.count == 1)
        #expect(model.analysisController.context?.blocks.count == 1)
    }

    @Test("previewOrphanCount: 0 while there is no valid analysis to lose, then counts exactly the ones lost")
    func previewOrphanCountReflectsRealAnalyses() async throws {
        let (model, cleanupDir) = try await makeReadyModel()
        defer { try? FileManager.default.removeItem(at: cleanupDir) }
        await model.applySummaryGranularity(.paragraph)

        // No analysis yet: switching to `.chapter` (which merges the two
        // blocks into one) loses nothing.
        let beforeAnyAnalysis = await model.previewOrphanCount(for: .chapter)
        #expect(beforeAnyAnalysis == 0)

        // Analyze (simulated) both current blocks.
        guard let fingerprint = model.storeFingerprint, let blockIds = model.documentRecord?.blocks.map(\.id), blockIds.count == 2 else {
            Issue.record("document not ready")
            return
        }
        await AppStore.shared.updateAnalysis(fingerprint: fingerprint) { analysis in
            for id in blockIds { analysis.blocks[id] = BlockAnalysis(status: .analyzed, title: "T") }
        }

        // Now switching to `.chapter` merges the two blocks (different
        // `textHash`/id): both valid analyses become orphans.
        let afterAnalysis = await model.previewOrphanCount(for: .chapter)
        #expect(afterAnalysis == 2)

        // And the real action confirms it: after applying, the old analyses
        // are `orphan` (never lost) and reported by `orphanBlocks`.
        await model.applySummaryGranularity(.chapter)
        #expect(model.orphanBlocks.count == 2)
        let finalAnalysis = await AppStore.shared.currentAnalysis(fingerprint: fingerprint)
        for id in blockIds {
            #expect(finalAnalysis?.blocks[id]?.status == .orphan)
        }
    }
}
