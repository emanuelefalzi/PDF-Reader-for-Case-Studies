import Foundation
import Testing
@testable import LelePdf

/// Regressions for the fix of the "right panel sometimes empty" bug.
/// Everything uses temporary folders: no access to Documents/Desktop/UserDefaults.
@Suite("Store · analysis protection from concurrent windows/processes", .serialized)
struct PanelDataLossRegressionTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LelePdfPanelSafety-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func analyzedBlock(_ title: String) -> BlockAnalysis {
        BlockAnalysis(
            status: .analyzed,
            analyzedAt: Date(),
            model: "sonnet",
            title: title,
            rewrite: [RewriteItem(kind: .summary, text: "Riscrittura \(title)")]
        )
    }

    private func register(_ store: DocumentStore, fingerprint: String) async {
        _ = await store.registerDocument(
            fingerprint: fingerprint,
            byteHash: nil,
            fileName: "documento.pdf",
            lastKnownPath: "/tmp/documento.pdf",
            title: "Documento",
            pageCount: 2
        )
    }

    @Test("an empty state created before loading does not replace a non-empty analisi.json")
    func emptyPendingCannotOverwriteExistingAnalysis() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = "12345678-empty-guard"
        let folder = root.appendingPathComponent(DocumentStore.folderName(title: "Documento", fingerprint: fingerprint))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var saved = AnalysisRecord()
        saved.blocks["b1"] = analyzedBlock("Buona")
        try AtomicJSONFile.write(
            AtomicJSONFile.encode(saved),
            to: folder.appendingPathComponent("analisi.json"),
            keepBackup: false
        )

        // Without an index/document the Store believes it is a new document
        // and creates an empty Pending: this is the most dangerous opening
        // order.
        let stale = DocumentStore(dataFolderURL: root)
        await register(stale, fingerprint: fingerprint)
        await stale.flush(fingerprint: fingerprint)

        let decoded = try #require(AtomicJSONFile.decode(
            AnalysisRecord.self,
            from: folder.appendingPathComponent("analisi.json")
        ))
        #expect(decoded.blocks["b1"]?.title == "Buona")
        #expect((await stale.currentAnalysis(fingerprint: fingerprint))?.blocks["b1"]?.title == "Buona")
    }

    @Test("two processes analyzing different blocks keep both")
    func concurrentStoresMergeDifferentBlocks() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = "12345678-concurrent"

        let seed = DocumentStore(dataFolderURL: root)
        await register(seed, fingerprint: fingerprint)
        await seed.updateAnalysis(fingerprint: fingerprint) { $0.blocks["b1"] = analyzedBlock("Uno") }
        await seed.flush(fingerprint: fingerprint)

        let firstProcess = DocumentStore(dataFolderURL: root)
        let secondProcess = DocumentStore(dataFolderURL: root)
        _ = await firstProcess.loadRecordAndAnalysis(fingerprint: fingerprint)
        _ = await secondProcess.loadRecordAndAnalysis(fingerprint: fingerprint)

        await secondProcess.updateAnalysis(fingerprint: fingerprint) { $0.blocks["b2"] = analyzedBlock("Due") }
        await secondProcess.flush(fingerprint: fingerprint)
        // The first process has a cache that predates b2 and modifies b1.
        await firstProcess.updateAnalysis(fingerprint: fingerprint) { $0.blocks["b1"] = analyzedBlock("Uno aggiornato") }
        await firstProcess.flush(fingerprint: fingerprint)

        let verifier = DocumentStore(dataFolderURL: root)
        let loaded = try #require(await verifier.loadRecordAndAnalysis(fingerprint: fingerprint)?.analysis)
        #expect(loaded.blocks["b1"]?.title == "Uno aggiornato")
        #expect(loaded.blocks["b2"]?.title == "Due")
    }

    @Test("a non-empty backup repairs an empty primary without being rotated away")
    func nonEmptyBackupSurvivesEmptyPrimary() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = "12345678-backup"
        let seed = DocumentStore(dataFolderURL: root)
        await register(seed, fingerprint: fingerprint)
        await seed.flush(fingerprint: fingerprint)
        let folderName = try #require(await seed.lookupFolder(forFingerprint: fingerprint))
        let primaryURL = root.appendingPathComponent(folderName).appendingPathComponent("analisi.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        var good = AnalysisRecord()
        good.blocks["b1"] = analyzedBlock("Dal backup")
        try AtomicJSONFile.write(AtomicJSONFile.encode(AnalysisRecord()), to: primaryURL, keepBackup: false)
        try AtomicJSONFile.write(AtomicJSONFile.encode(good), to: backupURL, keepBackup: false)

        let reopened = DocumentStore(dataFolderURL: root)
        let loaded = try #require(await reopened.loadRecordAndAnalysis(fingerprint: fingerprint)?.analysis)
        #expect(loaded.blocks["b1"]?.title == "Dal backup")

        let repaired = try #require(AtomicJSONFile.decode(AnalysisRecord.self, from: primaryURL))
        let preservedBackup = try #require(AtomicJSONFile.decode(AnalysisRecord.self, from: backupURL))
        #expect(repaired.blocks["b1"]?.title == "Dal backup")
        #expect(preservedBackup.blocks["b1"]?.title == "Dal backup")
    }
}
