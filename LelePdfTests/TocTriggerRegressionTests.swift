import Foundation
import Testing
@testable import LelePdf

/// Regression of the contents trigger bug (M5a deliverable 7, fixed in
/// `DocumentStore.updateStructure`): a `toc` that is already
/// `{source: .generated, entries: [...]}` must not be overwritten by a `toc`
/// `{source: .native, entries: []}` recomputed from the evaluation of the
/// built-in contents of the current session alone; otherwise a contents
/// generated in a previous session would disappear every time
/// `attachStructureToStore` calls `updateStructure` on a fresh open.
@Suite("TOC · trigger regression")
struct TocTriggerRegressionTests {
    private func tempDataFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfTocTriggerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a generated contents with entries is not overwritten by a native/empty one recomputed on reopen")
    func generatedTocSurvivesRecomputedNativeEmpty() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fingerprint = "fp-toc-regression"
        let store = DocumentStore(dataFolderURL: dir)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 10)

        let generated = TocRecord(source: .generated, entries: [
            TocEntryRecord(id: "gen-0", title: "Capitolo 1", level: 1, page: 0),
            TocEntryRecord(id: "gen-1", title: "Capitolo 2", level: 1, page: 5),
        ])
        _ = await store.updateStructure(fingerprint: fingerprint, toc: generated, segmentationVersion: 1, blocks: [], exhibits: [])

        // Reopen: the pipeline always runs again and recomputes a `toc` only
        // from the evaluation of the built-in contents of THIS session, which
        // does not distinguish "no useful built-in contents" from "no
        // contents": always labeled `native` with `entries: []` by the caller
        // (see `DocumentModel.attachStructureToStore`).
        let recomputedNativeEmpty = TocRecord(source: .native, entries: [])
        _ = await store.updateStructure(fingerprint: fingerprint, toc: recomputedNativeEmpty, segmentationVersion: 1, blocks: [], exhibits: [])

        let current = await store.currentRecord(fingerprint: fingerprint)
        #expect(current?.toc.source == .generated)
        #expect(current?.toc.entries.count == 2)
    }

    @Test("a newly generated toc (regeneration) replaces the previous one")
    func newGeneratedTocReplacesPrevious() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fingerprint = "fp-toc-regen"
        let store = DocumentStore(dataFolderURL: dir)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 10)

        let firstGenerated = TocRecord(source: .generated, entries: [TocEntryRecord(id: "gen-0", title: "Vecchio", level: 1, page: 0)])
        _ = await store.updateStructure(fingerprint: fingerprint, toc: firstGenerated, segmentationVersion: 1, blocks: [], exhibits: [])

        let newGenerated = TocRecord(source: .generated, entries: [TocEntryRecord(id: "gen-0", title: "Nuovo", level: 1, page: 0)])
        _ = await store.updateStructure(fingerprint: fingerprint, toc: newGenerated, segmentationVersion: 1, blocks: [], exhibits: [])

        let current = await store.currentRecord(fingerprint: fingerprint)
        #expect(current?.toc.entries.first?.title == "Nuovo")
    }

    @Test("no contents saved yet: the recomputed native/empty one is still applied")
    func nativeEmptyAppliedWhenNothingStoredYet() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fingerprint = "fp-toc-first"
        let store = DocumentStore(dataFolderURL: dir)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 10)

        let nativeEmpty = TocRecord(source: .native, entries: [])
        _ = await store.updateStructure(fingerprint: fingerprint, toc: nativeEmpty, segmentationVersion: 1, blocks: [], exhibits: [])

        let current = await store.currentRecord(fingerprint: fingerprint)
        #expect(current?.toc.source == .native)
        #expect(current?.toc.entries.isEmpty == true)
    }
}
