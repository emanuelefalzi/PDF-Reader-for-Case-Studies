import Foundation
import Testing
@testable import LelePdf

/// F10 (heading shortcuts): `ManualTocShortcut.apply`. ⌘⌥1…4 on the PDF
/// selection creates or changes the level of a T1-T4 entry, one piece per
/// entry on a multiple selection, in a single result array (so that
/// `DocumentModel` needs just one ⌘Z).
@Suite("ManualTocShortcut")
struct ManualTocShortcutTests {
    private func piece(_ title: String, page: Int, pageY: Double? = nil) -> ManualTocShortcut.Piece {
        ManualTocShortcut.Piece(page: page, title: title, pageY: pageY)
    }

    @Test("no existing entry: adds a new manual T-level entry")
    func addsNewEntry() {
        let result = ManualTocShortcut.apply(pieces: [piece("Nuovo titolo", page: 2, pageY: 400)], level: 2, entries: [])
        #expect(result.count == 1)
        #expect(result[0].title == "Nuovo titolo")
        #expect(result[0].level == 2)
        #expect(result[0].page == 2)
        #expect(result[0].pageY == 400)
        #expect(result[0].origin == .manual)
    }

    @Test("same title/page as an existing entry: changes level, does not duplicate")
    func changesLevelInsteadOfDuplicating() {
        let existing = TocEntryRecord(id: "manual-1", title: "Capitolo Due", level: 1, page: 5, origin: .manual)
        let result = ManualTocShortcut.apply(pieces: [piece("capitolo due", page: 5)], level: 3, entries: [existing])
        // editEntry (ManualToc) keeps the id for an already manual entry.
        #expect(result.count == 1)
        #expect(result[0].id == "manual-1")
        #expect(result[0].level == 3)
    }

    @Test("same title/page, level already equal: no change")
    func noOpWhenAlreadyAtLevel() {
        let existing = TocEntryRecord(id: "manual-1", title: "Capitolo Due", level: 2, page: 5, origin: .manual)
        let result = ManualTocShortcut.apply(pieces: [piece("Capitolo Due", page: 5)], level: 2, entries: [existing])
        #expect(result == [existing])
    }

    @Test("same title but different page: NOT the same entry, adds a new one")
    func differentPageIsNotTheSameEntry() {
        let existing = TocEntryRecord(id: "manual-1", title: "Introduzione", level: 1, page: 0, origin: .manual)
        let result = ManualTocShortcut.apply(pieces: [piece("Introduzione", page: 4)], level: 1, entries: [existing])
        #expect(result.count == 2)
        #expect(result.contains { $0.id == "manual-1" && $0.page == 0 })
        #expect(result.contains { $0.page == 4 && $0.title == "Introduzione" })
    }

    @Test("a tombstone (removed) with the same title does not count as existing: adds a new one")
    func tombstoneDoesNotCountAsExisting() {
        let tombstone = TocEntryRecord(id: "gen-0", title: "Vecchio capitolo", level: 1, page: 0, origin: .manual, removed: true)
        let result = ManualTocShortcut.apply(pieces: [piece("Vecchio capitolo", page: 0)], level: 1, entries: [tombstone])
        #expect(result.count == 2)
        #expect(result.contains { $0.removed == true })
        #expect(result.contains { $0.removed != true && $0.title == "Vecchio capitolo" })
    }

    @Test("multiple selection: one piece per entry, all at the same level, in a single array")
    func multiplePiecesBecomeMultipleEntriesAtSameLevel() {
        let pieces = [
            piece("Primo pezzo", page: 1, pageY: 500),
            piece("Secondo pezzo", page: 1, pageY: 300),
            piece("Terzo pezzo", page: 3, pageY: 200),
        ]
        let result = ManualTocShortcut.apply(pieces: pieces, level: 2, entries: [])
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.level == 2 })
        #expect(Set(result.map(\.title)) == Set(["Primo pezzo", "Secondo pezzo", "Terzo pezzo"]))
        // Distinct manual ids (incremental nextManualId, never duplicated
        // within the same batch).
        #expect(Set(result.map(\.id)).count == 3)
    }

    @Test("mixed multiple selection: one new piece and one piece that changes the level of an existing entry, in a single array")
    func multiplePiecesMixedAddAndChangeLevel() {
        let existing = TocEntryRecord(id: "manual-1", title: "Già presente", level: 1, page: 0, origin: .manual)
        let pieces = [piece("Già presente", page: 0), piece("Del tutto nuovo", page: 2)]
        let result = ManualTocShortcut.apply(pieces: pieces, level: 3, entries: [existing])
        #expect(result.count == 2)
        #expect(result.contains { $0.id == "manual-1" && $0.level == 3 })
        #expect(result.contains { $0.title == "Del tutto nuovo" && $0.level == 3 })
    }
}
