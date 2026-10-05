import Foundation
import Testing
@testable import LelePdf

/// `DocumentStore.updateCollapsedTocEntryIds` (the collapsed state is
/// remembered per document, in `documento.json`): same scheme as
/// `DocumentStoreManualTocTests`: a real `DocumentStore`, a write/read-back
/// round, and finally a real `documento.json` closed and reopened by a SECOND
/// `DocumentStore` to demonstrate backward compatibility (the field is absent
/// in a file written before collapsible contents existed).
@Suite("DocumentStore · collapsible contents")
struct DocumentStoreTocCollapseTests {
    private func tempDataFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfTocCollapseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("updateCollapsedTocEntryIds: saves, remains after updateStructure")
    @MainActor
    func collapsedIdsSurviveStructureUpdate() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp1"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)

        await store.updateCollapsedTocEntryIds(fingerprint: fingerprint, ids: ["t1a", "t2b"])
        _ = await store.updateStructure(fingerprint: fingerprint, toc: TocRecord(source: .native, entries: []), segmentationVersion: 1, blocks: [], exhibits: [])

        let record = await store.currentRecord(fingerprint: fingerprint)
        #expect(record?.collapsedTocEntryIds == ["t1a", "t2b"])
    }

    @Test("round trip: collapsedTocEntryIds survives reopening")
    @MainActor
    func collapsedIdsSurviveReopen() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fingerprint = "fp2"
        let store = DocumentStore(dataFolderURL: dir)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        await store.updateCollapsedTocEntryIds(fingerprint: fingerprint, ids: ["t2a"])
        await store.flush(fingerprint: fingerprint)

        let reopened = DocumentStore(dataFolderURL: dir)
        let loaded = try #require(await reopened.loadRecordAndAnalysis(fingerprint: fingerprint))
        #expect(loaded.record.collapsedTocEntryIds == ["t2a"])
    }

    @Test("backward compatibility: a documento.json without the field (written before collapsible contents) opens with no collapsed entries")
    @MainActor
    func missingFieldDecodesAsEmpty() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fingerprint = "fp3"
        let store = DocumentStore(dataFolderURL: dir)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        // First write a REAL value (otherwise `JSONEncoder` would omit the key
        // anyway for a `nil` `Optional`, as a file written before this
        // feature would; the test would prove nothing about DECODING without
        // first showing that the key CAN exist).
        await store.updateCollapsedTocEntryIds(fingerprint: fingerprint, ids: ["t1a"])
        await store.flush(fingerprint: fingerprint)

        // A documento.json written BEFORE this feature has no
        // "collapsedTocEntryIds" key at all. Simulated here by removing it
        // from the real JSON just written to disk, instead of trusting only
        // the in-memory struct default (which would prove nothing about
        // DECODING).
        let recordURL = try #require(FileManager.default
            .subpaths(atPath: dir.path)?
            .first { $0.hasSuffix("documento.json") }
            .map { dir.appendingPathComponent($0) })
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        #expect(json["collapsedTocEntryIds"] != nil, "the field must exist in a file written by THIS version, otherwise the test proves nothing")
        json.removeValue(forKey: "collapsedTocEntryIds")
        try JSONSerialization.data(withJSONObject: json).write(to: recordURL)

        let reopened = DocumentStore(dataFolderURL: dir)
        let loaded = try #require(await reopened.loadRecordAndAnalysis(fingerprint: fingerprint))
        #expect(loaded.record.collapsedTocEntryIds == nil)
        #expect(Set(loaded.record.collapsedTocEntryIds ?? []).isEmpty)
    }

    @Test("no-op: requesting the same set already saved does not touch updatedAt")
    @MainActor
    func noOpWhenUnchanged() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fingerprint = "fp4"
        let store = DocumentStore(dataFolderURL: dir)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        await store.updateCollapsedTocEntryIds(fingerprint: fingerprint, ids: ["t1a"])
        let firstUpdatedAt = await store.currentRecord(fingerprint: fingerprint)?.updatedAt

        try await Task.sleep(nanoseconds: 5_000_000)
        await store.updateCollapsedTocEntryIds(fingerprint: fingerprint, ids: ["t1a"])
        let secondUpdatedAt = await store.currentRecord(fingerprint: fingerprint)?.updatedAt

        #expect(firstUpdatedAt == secondUpdatedAt)
    }
}
