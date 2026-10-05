import Foundation
import Testing
@testable import LelePdf

/// Same class of protections as `PanelDataLossRegressionTests`, but for
/// `documento.json` (structure/progress) instead of `analisi.json`: before
/// the fix, `writeRecordNow` had neither a `.bak` nor a merge, so a
/// window/process with an older cache could silently regress
/// `progress.analyzedBlockIds`/`toc`/`blocks` on disk. Everything uses
/// temporary folders: no access to Documents/Desktop/UserDefaults.
@Suite("Store · documento.json protection from concurrent windows/processes", .serialized)
struct DocumentRecordDataLossRegressionTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LelePdfRecordSafety-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func register(_ store: DocumentStore, fingerprint: String) async -> String {
        let result = await store.registerDocument(
            fingerprint: fingerprint,
            byteHash: nil,
            fileName: "documento.pdf",
            lastKnownPath: "/tmp/documento.pdf",
            title: "Documento",
            pageCount: 2
        )
        return result.folderName
    }

    private func sampleBlocks() -> [BlockRecord] {
        [BlockRecord(id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "h1", words: 10)]
    }

    @Test("an empty/stale record does not replace a structure already saved on disk")
    func emptyPendingCannotOverwriteExistingStructure() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = "12345678-empty-record"
        let folder = root.appendingPathComponent(DocumentStore.folderName(title: "Documento", fingerprint: fingerprint))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var saved = DocumentRecord.blank(fingerprint: fingerprint, fileName: "documento.pdf", lastKnownPath: "/tmp/documento.pdf", pageCount: 2, title: "Documento")
        saved.blocks = sampleBlocks()
        saved.progress.analyzedBlockIds = ["b1"]
        try AtomicJSONFile.write(AtomicJSONFile.encode(saved), to: folder.appendingPathComponent("documento.json"), keepBackup: false)

        // With no index, the Store believes it is a new document and creates
        // an empty Pending: the most dangerous opening order, as for
        // `analisi.json` (PanelDataLossRegressionTests).
        let stale = DocumentStore(dataFolderURL: root)
        await register(stale, fingerprint: fingerprint)
        await stale.flush(fingerprint: fingerprint)

        let decoded = try #require(AtomicJSONFile.decode(DocumentRecord.self, from: folder.appendingPathComponent("documento.json")))
        #expect(decoded.blocks == sampleBlocks())
        #expect(decoded.progress.analyzedBlockIds == ["b1"])
    }

    @Test("two processes advancing progress on different blocks keep both ids")
    func concurrentStoresMergeAnalyzedBlockIds() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = "12345678-concurrent-record"

        let seed = DocumentStore(dataFolderURL: root)
        await register(seed, fingerprint: fingerprint)
        _ = await seed.updateStructure(
            fingerprint: fingerprint, toc: TocRecord(source: .native, entries: []),
            segmentationVersion: 1,
            blocks: [
                BlockRecord(id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "h1", words: 10),
                BlockRecord(id: "b2", sectionPath: [], pageStart: 1, pageEnd: 1, textHash: "h2", words: 10),
            ],
            exhibits: []
        )
        await seed.flush(fingerprint: fingerprint)

        let firstProcess = DocumentStore(dataFolderURL: root)
        let secondProcess = DocumentStore(dataFolderURL: root)
        _ = await firstProcess.loadRecordAndAnalysis(fingerprint: fingerprint)
        _ = await secondProcess.loadRecordAndAnalysis(fingerprint: fingerprint)

        await secondProcess.markBlockAnalyzed(fingerprint: fingerprint, blockId: "b2")
        await secondProcess.flush(fingerprint: fingerprint)
        // The first process has a cache older than b2 and advances b1: it
        // must not lose the progress of b2 already written by the second.
        await firstProcess.markBlockAnalyzed(fingerprint: fingerprint, blockId: "b1")
        await firstProcess.flush(fingerprint: fingerprint)

        let verifier = DocumentStore(dataFolderURL: root)
        let loaded = try #require(await verifier.loadRecordAndAnalysis(fingerprint: fingerprint)?.record)
        #expect(Set(loaded.progress.analyzedBlockIds) == ["b1", "b2"])
    }

    @Test("documento.json.bak is created on the second write and is never rotated away by a corrupted main file")
    func recordBackupSurvivesCorruption() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = "12345678-record-backup"
        let store = DocumentStore(dataFolderURL: root)
        let folderName = await register(store, fingerprint: fingerprint)

        await store.updateProgress(fingerprint: fingerprint, lastReadPage: 1)
        await store.flush(fingerprint: fingerprint)
        await store.updateProgress(fingerprint: fingerprint, lastReadPage: 2)
        await store.flush(fingerprint: fingerprint)

        let folder = root.appendingPathComponent(folderName)
        let backupURL = folder.appendingPathComponent("documento.json.bak")
        let backup = try #require(AtomicJSONFile.decode(DocumentRecord.self, from: backupURL))
        #expect(backup.progress.lastReadPage == 1)
        let current = try #require(AtomicJSONFile.decode(DocumentRecord.self, from: folder.appendingPathComponent("documento.json")))
        #expect(current.progress.lastReadPage == 2)

        // Corrupts the main file directly: a new actor must fall back to the
        // backup and repair it, as already happens for `analisi.json`
        // (DocumentStoreTests.corruptedAnalysisRecoversFromBackupOnReopen).
        try Data("{ non è json valido".utf8).write(to: folder.appendingPathComponent("documento.json"))
        let reopened = DocumentStore(dataFolderURL: root)
        let loaded = try #require(await reopened.loadRecordAndAnalysis(fingerprint: fingerprint)?.record)
        #expect(loaded.progress.lastReadPage == 1) // the .bak version, not the corrupted one
    }

    @Test("documento.json.session-start fixes the pre-session state exactly once, without accumulating")
    func sessionStartSafetyCopyIsFixedOnce() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = "12345678-session-start"

        let seed = DocumentStore(dataFolderURL: root)
        let folderName = await register(seed, fingerprint: fingerprint)
        await seed.updateProgress(fingerprint: fingerprint, lastReadPage: 1)
        await seed.flush(fingerprint: fingerprint)

        // New process/session on the same folder: finds page 1 on disk, then
        // moves it to 5. The first write of THIS session must fix "page 1"
        // as the pre-session state.
        let nextSession = DocumentStore(dataFolderURL: root)
        _ = await nextSession.loadRecordAndAnalysis(fingerprint: fingerprint)
        await nextSession.updateProgress(fingerprint: fingerprint, lastReadPage: 5)
        await nextSession.flush(fingerprint: fingerprint)

        let folder = root.appendingPathComponent(folderName)
        let sessionStartURL = folder.appendingPathComponent("documento.json.session-start")
        let sessionStart = try #require(AtomicJSONFile.decode(DocumentRecord.self, from: sessionStartURL))
        #expect(sessionStart.progress.lastReadPage == 1)

        // A second write in the SAME session must not touch the already
        // fixed copy, even if progress advances further.
        await nextSession.updateProgress(fingerprint: fingerprint, lastReadPage: 9)
        await nextSession.flush(fingerprint: fingerprint)
        let stillFirst = try #require(AtomicJSONFile.decode(DocumentRecord.self, from: sessionStartURL))
        #expect(stillFirst.progress.lastReadPage == 1)
    }
}
