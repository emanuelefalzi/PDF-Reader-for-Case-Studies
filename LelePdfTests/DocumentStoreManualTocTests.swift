import Foundation
import Testing
@testable import LelePdf

/// Manual level 1-4 contents in the Store (SPEC v2.3 §5.3, §8): manual
/// entries (added, changed, or removal tombstones) survive a re-evaluation of
/// the structure (`updateStructure`, on every open) and "Regenerate contents"
/// (`updateToc`), with deduplication; everything persists across reopening.
@Suite("DocumentStore · manual contents")
struct DocumentStoreManualTocTests {
    private func tempDataFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfManualTocTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("updateTocEntries: adds a manual entry, which remains after an updateStructure pass")
    @MainActor
    func manualEntrySurvivesStructureUpdate() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp1"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        _ = await store.updateStructure(fingerprint: fingerprint, toc: TocRecord(source: .native, entries: []), segmentationVersion: 1, blocks: [], exhibits: [])

        let manualEntry = TocEntryRecord(id: "manual-1", title: "Aggiunta a mano", level: 2, page: 3, origin: .manual, pageY: 400)
        await store.updateTocEntries(fingerprint: fingerprint) { $0.append(manualEntry) }

        // A new re-evaluation of the structure (as on every open, SPEC §7):
        // the manual entry must not disappear, even if the contents
        // re-evaluated in this session are again "no useful native contents".
        _ = await store.updateStructure(fingerprint: fingerprint, toc: TocRecord(source: .native, entries: []), segmentationVersion: 1, blocks: [], exhibits: [])

        let record = await store.currentRecord(fingerprint: fingerprint)
        #expect(record?.toc.entries.contains(manualEntry) == true)
    }

    @Test("updateToc (Regenerate contents): keeps manual entries/tombstones, replaces the automatic ones, dedupes")
    @MainActor
    func regenerateTocKeepsManualAndDedupes() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp2"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)

        let oldAuto = TocRecord(source: .generated, entries: [TocEntryRecord(id: "gen-0", title: "Vecchio capitolo", level: 1, page: 0)])
        await store.updateToc(fingerprint: fingerprint, toc: oldAuto)
        let manualAdd = TocEntryRecord(id: "manual-1", title: "Sezione aggiunta", level: 2, page: 1, origin: .manual)
        let tombstone = TocEntryRecord(id: "gen-0", title: "Vecchio capitolo", level: 1, page: 0, origin: .manual, removed: true)
        await store.updateTocEntries(fingerprint: fingerprint) { entries in
            entries.append(manualAdd)
            // Simulates "Remove" on the existing automatic entry (tombstone).
            if let index = entries.firstIndex(where: { $0.id == "gen-0" }) {
                entries[index] = tombstone
            }
        }

        // "Regenerate contents": an entry that duplicates "Sezione aggiunta"
        // (same page, same title ignoring case) must lose against the manual
        // one; a different new entry stays.
        let newAuto = TocRecord(source: .generated, entries: [
            TocEntryRecord(id: "gen-1", title: "sezione aggiunta", level: 2, page: 1),
            TocEntryRecord(id: "gen-2", title: "Capitolo nuovo", level: 1, page: 4),
        ])
        await store.updateToc(fingerprint: fingerprint, toc: newAuto)

        let entries = await store.currentRecord(fingerprint: fingerprint)?.toc.entries ?? []
        #expect(entries.contains { $0.id == "manual-1" })
        #expect(entries.contains { $0.id == "gen-0" && $0.removed == true }) // tombstone kept
        #expect(!entries.contains { $0.id == "gen-1" }) // duplicate of the manual one, discarded
        #expect(entries.contains { $0.id == "gen-2" }) // genuinely new automatic entry
    }

    @Test("round trip: origin/pageY/removed survive reopening")
    @MainActor
    func manualTocFieldsSurviveReopen() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fingerprint = "fp3"
        let store = DocumentStore(dataFolderURL: dir)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        let entry = TocEntryRecord(id: "manual-1", title: "T2 di prova", level: 2, page: 2, origin: .manual, pageY: 321.5)
        await store.updateTocEntries(fingerprint: fingerprint) { $0.append(entry) }
        await store.flush(fingerprint: fingerprint)

        let reopened = DocumentStore(dataFolderURL: dir)
        let loaded = try #require(await reopened.loadRecordAndAnalysis(fingerprint: fingerprint))
        #expect(loaded.record.toc.entries.contains(entry))
    }

    @Test("visible/sorted applied together: a tombstone does not appear, the order respects pageY")
    @MainActor
    func visibleAndSortedIntegration() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fingerprint = "fp4"
        let store = DocumentStore(dataFolderURL: dir)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 5)
        await store.updateTocEntries(fingerprint: fingerprint) { entries in
            entries.append(TocEntryRecord(id: "a", title: "In basso", level: 1, page: 0, origin: .manual, pageY: 100))
            entries.append(TocEntryRecord(id: "b", title: "In alto", level: 1, page: 0, origin: .manual, pageY: 500))
            entries.append(TocEntryRecord(id: "c", title: "Tombstone", level: 1, page: 1, origin: .manual, removed: true))
        }
        let entries = await store.currentRecord(fingerprint: fingerprint)?.toc.entries ?? []
        let display = ManualToc.sorted(ManualToc.visible(entries))
        #expect(display.map(\.id) == ["b", "a"])
    }
}
