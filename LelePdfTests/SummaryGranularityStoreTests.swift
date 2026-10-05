import Foundation
import Testing
@testable import LelePdf

/// F8 (summary granularity): `DocumentStore.updateSummaryGranularity`
/// (persistence of the choice) and `DocumentStore.reattach` (the pure preview
/// used by `DocumentModel.previewOrphanCount` BEFORE asking the user to
/// confirm: "N summaries will have to be redone").
@Suite("F8 · Store: granularity and change preview")
struct SummaryGranularityStoreTests {
    private func tempDataFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("registerDocument on a NEW document immediately receives the default; an existing document never does")
    func newDocumentReceivesDefaultExistingDoesNot() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)

        let created = await store.registerDocument(
            fingerprint: "fp-new", byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf",
            title: "A", pageCount: 5, initialSummaryGranularity: .chapter
        )
        #expect(created.isNew)
        #expect(created.record.summaryGranularity == .chapter)

        // Reopened with a DIFFERENT default in the meantime (Settings
        // changed): the already registered document does not receive it.
        let reopened = await store.registerDocument(
            fingerprint: "fp-new", byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf",
            title: "A", pageCount: 5, initialSummaryGranularity: .paragraph
        )
        #expect(!reopened.isNew)
        #expect(reopened.record.summaryGranularity == .chapter)
    }

    @Test("updateSummaryGranularity: saves the choice, no-op if unchanged")
    func updateSummaryGranularityPersistsChoice() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-granularity"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        #expect(await store.currentRecord(fingerprint: fingerprint)?.summaryGranularity == nil)

        await store.updateSummaryGranularity(fingerprint: fingerprint, granularity: .heading2)
        #expect(await store.currentRecord(fingerprint: fingerprint)?.summaryGranularity == .heading2)

        await store.flush(fingerprint: fingerprint)
        let (reloadedRecord, _, _) = try #require(await store.loadRecordAndAnalysis(fingerprint: fingerprint))
        #expect(reloadedRecord.summaryGranularity == .heading2)
    }

    @Test("pure reattach: same result as updateStructure, without writing anything")
    func pureReattachMatchesUpdateStructure() {
        let previous = [
            BlockRecord(id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "h1", words: 100),
            BlockRecord(id: "b2", sectionPath: [], pageStart: 1, pageEnd: 1, textHash: "h2", words: 100),
        ]
        let new = [
            BlockRecord(id: "b1-new", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "h1", words: 100),
        ]
        let analysisBlocks: [String: BlockAnalysis] = [
            "b1": BlockAnalysis(status: .analyzed, title: "Uno"),
            "b2": BlockAnalysis(status: .analyzed, title: "Due"),
        ]
        let result = DocumentStore.reattach(previousBlocks: previous, newBlocks: new, analysisBlocks: analysisBlocks)
        #expect(result.orphans == [OrphanBlock(blockId: "b2", page: 1)])
        #expect(result.reattached["b1-new"]?.title == "Uno")
        #expect(result.reattached["b2"]?.status == .orphan)
    }

    @Test("usePositionalFallback: false avoids a false reattachment when the granularity changes how many blocks fall on each page")
    func positionalFallbackDisabledAvoidsFalseMatchOnGranularityChange() {
        // Old granularity (paragraph): one block per page. New granularity
        // (chapter): a single merged block covering both pages.
        // `positionalMatches` (by start page ONLY) would wrongly attach page
        // 0's analysis to the merged block.
        let previous = [
            BlockRecord(id: "p0", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "hash-p0", words: 30),
            BlockRecord(id: "p1", sectionPath: [], pageStart: 1, pageEnd: 1, textHash: "hash-p1", words: 30),
        ]
        let merged = [BlockRecord(id: "chapter", sectionPath: [], pageStart: 0, pageEnd: 1, textHash: "hash-merged", words: 60)]
        let analysisBlocks: [String: BlockAnalysis] = [
            "p0": BlockAnalysis(status: .analyzed, title: "P0"),
            "p1": BlockAnalysis(status: .analyzed, title: "P1"),
        ]

        // With the positional fallback (the usual behavior): p0 is (falsely)
        // reattached to the merged block.
        let withFallback = DocumentStore.reattach(previousBlocks: previous, newBlocks: merged, analysisBlocks: analysisBlocks)
        #expect(withFallback.reattached["chapter"]?.status == .analyzed)

        // Without it (granularity change): id/textHash only; both honestly
        // become orphans, none is reattached wrongly.
        let withoutFallback = DocumentStore.reattach(previousBlocks: previous, newBlocks: merged, analysisBlocks: analysisBlocks, usePositionalFallback: false)
        #expect(withoutFallback.orphans.count == 2)
        #expect(withoutFallback.reattached["chapter"] == nil)
        #expect(withoutFallback.reattached["p0"]?.status == .orphan)
        #expect(withoutFallback.reattached["p1"]?.status == .orphan)
    }

    @Test("requireExactSpanForIdMatch: an id that matches by construction (a merged block that starts like the old one) does not reattach if the span is different")
    func requireExactSpanAvoidsFalseIdMatchOnMerge() {
        // A block's id (SPEC §7.3) depends on section + first 60 characters +
        // STARTING PAGE, not on the end page. A "grown" block (p0 also
        // absorbs p1) has, by construction, THE SAME id as the old p0 if it
        // starts with the same text on the same page.
        let sameId = BlockSegmenter.segment(paragraphs: [PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(10))]).first!.id
        let previous = [BlockRecord(id: sameId, sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "hash-small", words: 10)]
        // Same ID, but now the span reaches p.2 and the text is different
        // (it also contains p1/p2): a "true" reattachment by id here would be
        // incorrect.
        let merged = [BlockRecord(id: sameId, sectionPath: [], pageStart: 0, pageEnd: 2, textHash: "hash-merged", words: 90)]
        let analysisBlocks: [String: BlockAnalysis] = [sameId: BlockAnalysis(status: .analyzed, title: "Solo p0")]

        let withoutGuard = DocumentStore.reattach(previousBlocks: previous, newBlocks: merged, analysisBlocks: analysisBlocks)
        #expect(withoutGuard.reattached[sameId]?.status == .analyzed) // the generic behavior accepts the id alone

        let withGuard = DocumentStore.reattach(previousBlocks: previous, newBlocks: merged, analysisBlocks: analysisBlocks, usePositionalFallback: false, requireExactSpanForIdMatch: true)
        #expect(withGuard.orphans.map(\.blockId) == [sameId])
        #expect(withGuard.reattached[sameId]?.status == .orphan)
    }

    @Test("requireExactSpanForIdMatch: an id that matches with the SAME span stays a real reattachment")
    func requireExactSpanKeepsRealIdMatch() {
        let sameId = BlockSegmenter.segment(paragraphs: [PipelineFixtures.paragraph(page: 0, text: PipelineFixtures.words(10))]).first!.id
        let previous = [BlockRecord(id: sameId, sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "hash-a", words: 10)]
        let unchanged = [BlockRecord(id: sameId, sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "hash-a-edited", words: 11)]
        let analysisBlocks: [String: BlockAnalysis] = [sameId: BlockAnalysis(status: .analyzed, title: "Uguale")]
        let result = DocumentStore.reattach(previousBlocks: previous, newBlocks: unchanged, analysisBlocks: analysisBlocks, usePositionalFallback: false, requireExactSpanForIdMatch: true)
        #expect(result.reattached[sameId]?.status == .analyzed)
        #expect(result.orphans.isEmpty)
    }

    @Test("preview: a .failed block (never succeeded) that becomes an orphan does not count as a 'summary to redo'")
    func previewCountsOnlyAnalyzedBlocksThatBecomeOrphaned() {
        // Two blocks per page before, only one after (different count per
        // page): no positional fallback possible, `b1` is honestly orphaned by
        // id/textHash, regardless of `usePositionalFallback`, changed on
        // purpose here to isolate the "which statuses count" rule alone from
        // the one tested above.
        let previous = [
            BlockRecord(id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "h1", words: 50),
            BlockRecord(id: "b2", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "h2", words: 50),
        ]
        let new = [BlockRecord(id: "b-new", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "different", words: 100)]
        let analysisBlocks: [String: BlockAnalysis] = ["b1": BlockAnalysis(status: .failed)]
        let result = DocumentStore.reattach(previousBlocks: previous, newBlocks: new, analysisBlocks: analysisBlocks, usePositionalFallback: false)
        #expect(result.orphans.count == 1) // an orphan, yes...
        let affected = Set(result.orphans.map(\.blockId)).filter { analysisBlocks[$0]?.status == .analyzed }.count
        #expect(affected == 0) // ...but not a VALID summary lost (it never succeeded)
    }
}
