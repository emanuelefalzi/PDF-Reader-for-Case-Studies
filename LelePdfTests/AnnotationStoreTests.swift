import Testing
import Foundation
@testable import LelePdf

/// `annotazioni.json` in the `DocumentStore` (SPEC §8, §5.13): same
/// pattern as `DocumentStoreTests` — round trip, atomic write, debounce,
/// included in `flush`. Temporary folders, never `~/Documents`.
@Suite("DocumentStore+Annotations", .serialized)
struct AnnotationStoreTests {
    private func tempDataFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfAnnotationStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `createdAt`/`updatedAt` in whole seconds (not `Date()`, which has
    /// sub-seconds): `AtomicJSONFile` encodes dates as ISO8601 without
    /// fractional seconds, so a round trip with `Date()` would round the
    /// decoded date, making the equality comparison fail even when every other
    /// field matches.
    private func sampleItems() -> [Annotation] {
        let when = Date(timeIntervalSince1970: 1_726_000_000)
        return [
            Annotation(id: "a1", page: 0, kind: .highlight, color: AnnotationColor(red: 1, green: 0.9, blue: 0.25, alpha: 0.55), rect: AnnotationRect(x: 10, y: 10, width: 80, height: 12), text: "termine evidenziato", createdAt: when, updatedAt: when),
            Annotation(id: "a2", page: 1, kind: .note, color: AnnotationColor(red: 1, green: 0.9, blue: 0.25, alpha: 1), rect: AnnotationRect(x: 20, y: 20, width: 22, height: 22), text: "promemoria", createdAt: when, updatedAt: when),
        ]
    }

    @Test("round trip: saves annotations, reopens with a new actor on the same folder")
    func saveThenLoadRoundTrip() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-annotations-roundtrip"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)

        let items = sampleItems()
        await store.updateAnnotations(fingerprint: fingerprint) { $0.items = items }
        await store.flush(fingerprint: fingerprint)

        let reopened = DocumentStore(dataFolderURL: dir)
        let loaded = try #require(await reopened.loadRecordAndAnalysis(fingerprint: fingerprint))
        #expect(loaded.annotations.items == items)
    }

    @Test("flush writes annotazioni.json immediately, without waiting for the debounce")
    func flushWritesImmediately() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-annotations-flush"
        let registered = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        await store.updateAnnotations(fingerprint: fingerprint) { $0.items = sampleItems() }
        await store.flush(fingerprint: fingerprint)

        let url = dir.appendingPathComponent(registered.folderName).appendingPathComponent("annotazioni.json")
        let onDisk = AtomicJSONFile.decode(AnnotationsRecord.self, from: url)
        #expect(onDisk?.items.count == 2)
    }

    @Test("N rapid changes produce a single write (debounce)")
    func debounceCoalescesRapidWrites() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-annotations-debounce"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        await store.flush(fingerprint: fingerprint)

        for index in 0 ..< 5 {
            await store.updateAnnotations(fingerprint: fingerprint) { record in
                record.items = [Annotation(id: "a\(index)", page: 0, kind: .note, color: AnnotationColor(red: 1, green: 1, blue: 0, alpha: 1), rect: AnnotationRect(x: 0, y: 0, width: 20, height: 20))]
            }
        }
        let before = await store.annotationWriteCount
        try await Task.sleep(for: .milliseconds(750))
        let after = await store.annotationWriteCount
        #expect(after == before + 1)

        let current = await store.currentAnnotations(fingerprint: fingerprint)
        #expect(current?.items.first?.id == "a4") // the last state wins
    }

    @Test("no annotations saved: annotazioni.json does not exist, loading returns an empty record")
    func missingFileYieldsEmptyRecord() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-annotations-empty"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        await store.flush(fingerprint: fingerprint) // no annotation created: annotazioni.json does not exist.

        let reopened = DocumentStore(dataFolderURL: dir)
        let loaded = try #require(await reopened.loadRecordAndAnalysis(fingerprint: fingerprint))
        #expect(loaded.annotations.items.isEmpty)
        #expect(loaded.annotations.version == 1)
    }
}
