import Foundation
import Testing
@testable import LelePdf

/// Manual T1-T4 contents (SPEC v2.3 §5.3, §8; M7 brief deliverable 3b):
/// title cleanup, sorting, merging with "Regenerate contents", deduplication,
/// and tree indentation.
@Suite("ManualToc")
struct ManualTocTests {
    @Test("cleanTitle: newlines -> spaces, end-of-line hyphenation joined, whitespace cleaned")
    func cleanTitle() {
        #expect(ManualToc.cleanTitle("Capitolo\nUno") == "Capitolo Uno")
        #expect(ManualToc.cleanTitle("Concor-\nrenza") == "Concorrenza")
        #expect(ManualToc.cleanTitle("  Molti   spazi  ") == "Molti spazi")
    }

    @Test("sorted: by page, then by descending pageY")
    func sortedOrder() {
        let entries = [
            TocEntryRecord(id: "a", title: "A", level: 1, page: 1, pageY: 100),
            TocEntryRecord(id: "b", title: "B", level: 1, page: 0, pageY: 200),
            TocEntryRecord(id: "c", title: "C", level: 1, page: 0, pageY: 700),
        ]
        let sorted = ManualToc.sorted(entries)
        #expect(sorted.map(\.id) == ["c", "b", "a"])
    }

    @Test("sorted: without pageY, keeps arrival order within the same page")
    func sortedStableWithoutPageY() {
        let entries = [
            TocEntryRecord(id: "a", title: "A", level: 1, page: 0),
            TocEntryRecord(id: "b", title: "B", level: 2, page: 0),
        ]
        #expect(ManualToc.sorted(entries).map(\.id) == ["a", "b"])
    }

    @Test("merge: manual entries stay, the new automatic ones replace the old ones")
    func mergeReplacesAuto() {
        let manual = [TocEntryRecord(id: "manual-1", title: "Aggiunta a mano", level: 2, page: 3, origin: .manual)]
        let oldAuto = [TocEntryRecord(id: "gen-0", title: "Vecchio", level: 1, page: 0)]
        let newAuto = [TocEntryRecord(id: "gen-1", title: "Nuovo", level: 1, page: 0)]
        // Simulates the sequence: first oldAuto is generated (it does not go
        // through merge here, the real caller is DocumentStore), then
        // "Regenerate contents" with newAuto: `merge` receives only the current
        // manual entries plus the new automatic ones.
        let merged = ManualToc.merge(manual: manual, newAuto: newAuto)
        #expect(merged.contains { $0.id == "manual-1" })
        #expect(merged.contains { $0.id == "gen-1" })
        #expect(!merged.contains { $0.id == "gen-0" })
    }

    @Test("merge: an automatic entry that duplicates a manual one (same page, same title) is discarded")
    func mergeDedupes() {
        let manual = [TocEntryRecord(id: "manual-1", title: "Capitolo Due", level: 1, page: 5, origin: .manual)]
        let newAuto = [
            TocEntryRecord(id: "gen-0", title: "capitolo due", level: 1, page: 5),
            TocEntryRecord(id: "gen-1", title: "Capitolo Tre", level: 1, page: 9),
        ]
        let merged = ManualToc.merge(manual: manual, newAuto: newAuto)
        #expect(merged.count == 2)
        #expect(merged.contains { $0.id == "manual-1" })
        #expect(!merged.contains { $0.id == "gen-0" })
        #expect(merged.contains { $0.id == "gen-1" })
    }

    @Test("visible: hides tombstones (removed)")
    func visibleHidesTombstones() {
        let entries = [
            TocEntryRecord(id: "a", title: "A", level: 1, page: 0),
            TocEntryRecord(id: "b", title: "B", level: 1, page: 1, origin: .manual, removed: true),
        ]
        #expect(ManualToc.visible(entries).map(\.id) == ["a"])
    }

    @Test("indentDepths: T2 under the previous T1, T3 without a T2 attaches to the T1")
    func indentDepthsWithOrphanLevel() {
        // T1, T3 (orphan, attaches to T1), T2 (afterwards, reopens level 2)
        let depths = ManualToc.indentDepths(levels: [1, 3, 2])
        #expect(depths == [0, 1, 1])
    }

    @Test("indentDepths: regular nested hierarchy T1-T2-T3-T4")
    func indentDepthsRegular() {
        #expect(ManualToc.indentDepths(levels: [1, 2, 3, 4]) == [0, 1, 2, 3])
    }

    @Test("indentDepths: two consecutive T1s both stay at depth 0")
    func indentDepthsSiblingTopLevel() {
        #expect(ManualToc.indentDepths(levels: [1, 2, 1]) == [0, 1, 0])
    }
}
