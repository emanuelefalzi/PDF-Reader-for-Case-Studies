import Testing
import Foundation
@preconcurrency import PDFKit
@testable import LelePdf

/// Tests for the `DocumentStore` actor (SPEC §8, §10.2, §11): round trip,
/// grouped atomic write, fingerprint index, renaming, re-attachment of
/// orphan analyses. Always on temporary folders, never `~/Documents`.
@Suite("DocumentStore")
struct DocumentStoreTests {
    private func tempDataFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("round trip: registers, updates structure and analysis, reloads with a new actor")
    @MainActor
    func saveThenLoadRoundTrip() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fingerprint = "fp-roundtrip"
        let store = DocumentStore(dataFolderURL: dir)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: "hash-1", fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "Documento A", pageCount: 5)
        _ = await store.updateStructure(
            fingerprint: fingerprint, toc: TocRecord(source: .native, entries: []),
            segmentationVersion: 1, blocks: StoreFixtures.sampleBlocks(), exhibits: StoreFixtures.sampleExhibits()
        )
        let analysis = StoreFixtures.sampleAnalysisRecord()
        await store.updateAnalysis(fingerprint: fingerprint) { $0 = analysis }
        await store.flush(fingerprint: fingerprint)

        // New actor on the same folder: simulates reopening the app.
        let reopened = DocumentStore(dataFolderURL: dir)
        let loaded = await reopened.loadRecordAndAnalysis(fingerprint: fingerprint)
        let result = try #require(loaded)
        #expect(result.record.blocks == StoreFixtures.sampleBlocks())
        #expect(result.record.exhibits == StoreFixtures.sampleExhibits())
        #expect(result.analysis == analysis)
    }

    @Test("flush writes immediately, without waiting for the debounce")
    func flushWritesImmediately() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-flush"
        let registered = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        await store.updateProgress(fingerprint: fingerprint, lastReadPage: 3)
        await store.flush(fingerprint: fingerprint)

        let documentoURL = dir.appendingPathComponent(registered.folderName).appendingPathComponent("documento.json")
        let onDisk = AtomicJSONFile.decode(DocumentRecord.self, from: documentoURL)
        #expect(onDisk?.progress.lastReadPage == 3)
    }

    @Test("N rapid writes produce a single write on disk (debounce)")
    func debounceCoalescesRapidWrites() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-debounce"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 10)
        // Registration has already scheduled a write: wait for it to drain
        // before measuring the debounce of the following calls.
        await store.flush(fingerprint: fingerprint)

        for page in 1 ... 5 {
            await store.updateProgress(fingerprint: fingerprint, lastReadPage: page)
        }
        let before = await store.recordWriteCount
        try await Task.sleep(for: .milliseconds(750))
        let after = await store.recordWriteCount

        #expect(after == before + 1) // 5 rapid calls → a single write
        let record = await store.currentRecord(fingerprint: fingerprint)
        #expect(record?.progress.lastReadPage == 5) // the last state wins
    }

    @Test("analisi.json.bak is created on the second write and holds the previous version")
    func analysisBackupThroughStore() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-backup"
        let registered = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)

        await store.updateAnalysis(fingerprint: fingerprint) { $0.terms["t1"] = TermRecord(term: "prima versione", type: .rectangle, firstBlockId: "b1") }
        await store.flush(fingerprint: fingerprint)
        await store.updateAnalysis(fingerprint: fingerprint) { $0.terms["t1"] = TermRecord(term: "seconda versione", type: .rectangle, firstBlockId: "b1") }
        await store.flush(fingerprint: fingerprint)

        let folder = dir.appendingPathComponent(registered.folderName)
        let backup = AtomicJSONFile.decode(AnalysisRecord.self, from: folder.appendingPathComponent("analisi.json.bak"))
        #expect(backup?.terms["t1"]?.term == "prima versione")
        let current = AtomicJSONFile.decode(AnalysisRecord.self, from: folder.appendingPathComponent("analisi.json"))
        #expect(current?.terms["t1"]?.term == "seconda versione")
    }

    @Test("corrupted analisi.json on disk: a new actor falls back to .bak, without staying corrupted")
    func corruptedAnalysisRecoversFromBackupOnReopen() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-corrupt"
        let registered = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)

        await store.updateAnalysis(fingerprint: fingerprint) { $0.terms["t1"] = TermRecord(term: "valida", type: .circle, firstBlockId: "b1") }
        await store.flush(fingerprint: fingerprint)
        await store.updateAnalysis(fingerprint: fingerprint) { $0.terms["t1"] = TermRecord(term: "valida 2", type: .circle, firstBlockId: "b1") }
        await store.flush(fingerprint: fingerprint)

        // Corrupts the main file directly (outside the Store, as an
        // interruption mid-write would without going through
        // `AtomicJSONFile`).
        let analisiURL = dir.appendingPathComponent(registered.folderName).appendingPathComponent("analisi.json")
        try Data("{ questo non è json valido".utf8).write(to: analisiURL)

        let reopened = DocumentStore(dataFolderURL: dir)
        let loaded = try #require(await reopened.loadRecordAndAnalysis(fingerprint: fingerprint))
        #expect(loaded.analysis.terms["t1"]?.term == "valida") // the .bak version, not the corrupted one

        // The main file was repaired: it does not stay corrupted on disk.
        let repaired = AtomicJSONFile.decode(AnalysisRecord.self, from: analisiURL)
        #expect(repaired?.terms["t1"]?.term == "valida")
    }

    @Test("saved analyses re-attach to the new blocks by id or by textHash; the others become orphans")
    func reattachAnalysesAfterResegmentation() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-orphan"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)

        let originalBlocks = [
            BlockRecord(id: "b1", sectionPath: ["Cap 1"], pageStart: 0, pageEnd: 0, textHash: "hash-b1", words: 100),
            BlockRecord(id: "b2", sectionPath: ["Cap 1"], pageStart: 1, pageEnd: 1, textHash: "hash-b2", words: 200),
        ]
        _ = await store.updateStructure(fingerprint: fingerprint, toc: TocRecord(source: .native, entries: []), segmentationVersion: 1, blocks: originalBlocks, exhibits: [])
        await store.updateAnalysis(fingerprint: fingerprint) {
            $0.blocks["b1"] = BlockAnalysis(status: .analyzed, title: "Blocco 1")
            $0.blocks["b2"] = BlockAnalysis(status: .analyzed, title: "Blocco 2")
        }
        await store.flush(fingerprint: fingerprint)

        // Reclassification: b1 becomes "b1-nuovo" with the same text (same
        // textHash, re-attaches); b2 disappears with no match (becomes an
        // orphan, stays at its old page).
        let newBlocks = [
            BlockRecord(id: "b1-nuovo", sectionPath: ["Cap 1"], pageStart: 0, pageEnd: 0, textHash: "hash-b1", words: 100),
        ]
        let orphans = await store.updateStructure(fingerprint: fingerprint, toc: TocRecord(source: .native, entries: []), segmentationVersion: 2, blocks: newBlocks, exhibits: [])

        #expect(orphans == [OrphanBlock(blockId: "b2", page: 1)])
        let analysis = try #require(await store.currentAnalysis(fingerprint: fingerprint))
        #expect(analysis.blocks["b1-nuovo"]?.title == "Blocco 1")
        #expect(analysis.blocks["b1"] == nil)
        #expect(analysis.blocks["b2"]?.status == .orphan)
    }

    @Test("text changed but same split (duplicate letters removed): re-attachment by position within the page, no orphans")
    func reattachByPositionWhenOnlyTextChanged() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-position"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        let original = [
            BlockRecord(id: "a1", sectionPath: ["Teeam"], pageStart: 0, pageEnd: 0, textHash: "h-a1", words: 100),
            BlockRecord(id: "a2", sectionPath: ["Teeam"], pageStart: 0, pageEnd: 1, textHash: "h-a2", words: 100),
            BlockRecord(id: "a3", sectionPath: ["Teeam"], pageStart: 2, pageEnd: 2, textHash: "h-a3", words: 100),
        ]
        _ = await store.updateStructure(fingerprint: fingerprint, toc: TocRecord(source: .native, entries: []), segmentationVersion: 2, blocks: original, exhibits: [])
        await store.updateAnalysis(fingerprint: fingerprint) {
            $0.blocks["a1"] = BlockAnalysis(status: .analyzed, title: "Uno")
            $0.blocks["a2"] = BlockAnalysis(status: .analyzed, title: "Due")
            $0.blocks["a3"] = BlockAnalysis(status: .analyzed, title: "Tre")
        }
        // Page 0: same 2 blocks, different text → position. Page 2: becomes
        // 2 blocks → different count, a3 stays orphan.
        let changed = [
            BlockRecord(id: "n1", sectionPath: ["Team"], pageStart: 0, pageEnd: 0, textHash: "x1", words: 100),
            BlockRecord(id: "n2", sectionPath: ["Team"], pageStart: 0, pageEnd: 1, textHash: "x2", words: 100),
            BlockRecord(id: "n3", sectionPath: ["Team"], pageStart: 2, pageEnd: 2, textHash: "x3", words: 50),
            BlockRecord(id: "n4", sectionPath: ["Team"], pageStart: 2, pageEnd: 2, textHash: "x4", words: 50),
        ]
        let orphans = await store.updateStructure(fingerprint: fingerprint, toc: TocRecord(source: .native, entries: []), segmentationVersion: 3, blocks: changed, exhibits: [])

        #expect(orphans == [OrphanBlock(blockId: "a3", page: 2)])
        let analysis = try #require(await store.currentAnalysis(fingerprint: fingerprint))
        #expect(analysis.blocks["n1"]?.title == "Uno")
        #expect(analysis.blocks["n2"]?.title == "Due")
        #expect(analysis.blocks["n1"]?.status == .analyzed)
    }

    @Test("renamed PDF: found again via the byte hash, and the rename updates fileName/lastKnownPath")
    @MainActor
    func renamedFileIsFoundAgainAndUpdatesPath() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: Merck PDF not found at \(TestPDFs.merck.path)")
            return
        }
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)

        let fingerprint = try #require(StoreFixtures.fingerprint(ofPDFAt: TestPDFs.merck))
        let originalHash = try #require(DocumentStore.hashFileBytes(at: TestPDFs.merck))
        let registered = await store.registerDocument(
            fingerprint: fingerprint, byteHash: originalHash, fileName: "merck.pdf",
            lastKnownPath: TestPDFs.merck.path, title: "Merck", pageCount: 37
        )
        #expect(registered.isNew)
        await store.flush(fingerprint: fingerprint)

        // Temporary local copy under another name, only for the test (never
        // in the repository, deleted at the end).
        let renamedDir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfRenameTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: renamedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: renamedDir) }
        let renamedURL = renamedDir.appendingPathComponent("strategia-rinominata.pdf")
        try FileManager.default.copyItem(at: TestPDFs.merck, to: renamedURL)

        // Fast path: same bytes, different name → found immediately through
        // the hash, without having to recompute the real fingerprint.
        let fastResult = await store.fastLookup(fileURL: renamedURL)
        #expect(fastResult.fingerprint == fingerprint)
        #expect(fastResult.byteHash == originalHash)
        #expect(fastResult.record?.fileName == "merck.pdf") // not yet updated

        // As the model would after the pipeline: registers again with the new
        // name/path → same folder, fileName/lastKnownPath updated.
        let reregistered = await store.registerDocument(
            fingerprint: fingerprint, byteHash: originalHash, fileName: renamedURL.lastPathComponent,
            lastKnownPath: renamedURL.path, title: "Merck", pageCount: 37
        )
        #expect(!reregistered.isNew)
        #expect(reregistered.folderName == registered.folderName)
        #expect(reregistered.record.fileName == "strategia-rinominata.pdf")
        #expect(reregistered.record.lastKnownPath == renamedURL.path)

        await store.flush(fingerprint: fingerprint)
        let onDisk = AtomicJSONFile.decode(DocumentRecord.self, from: dir.appendingPathComponent(registered.folderName).appendingPathComponent("documento.json"))
        #expect(onDisk?.fileName == "strategia-rinominata.pdf")
    }

    @Test("fingerprint unchanged after a metadata-only change; the byte hash changes")
    @MainActor
    func fingerprintStableAcrossMetadataOnlyChange() throws {
        let originalURL = try StoreFixtures.makeTextPDF(text: "Testo stabile per il calcolo dell'impronta.")
        defer { try? FileManager.default.removeItem(at: originalURL.deletingLastPathComponent()) }

        let originalDocument = try #require(PDFDocument(url: originalURL))
        let fingerprintBefore = DocumentFingerprint.compute(for: originalDocument)
        let hashBefore = try #require(DocumentStore.hashFileBytes(at: originalURL))

        originalDocument.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Titolo nuovo di zecca"]
        let editedURL = originalURL.deletingLastPathComponent().appendingPathComponent("modificato.pdf")
        #expect(originalDocument.write(to: editedURL))

        let editedDocument = try #require(PDFDocument(url: editedURL))
        let fingerprintAfter = DocumentFingerprint.compute(for: editedDocument)
        let hashAfter = try #require(DocumentStore.hashFileBytes(at: editedURL))

        #expect(fingerprintAfter == fingerprintBefore)
        #expect(hashAfter != hashBefore)
    }
}
