import Foundation

/// Manual T1-T4 contents (SPEC v2.3 §5.3, §8): pure functions for title
/// cleaning, ordering, merging with the automatic generation, deduplication
/// and tree indentation. Neither depends on PDFKit or on the Store:
/// `DocumentModel`/`DocumentStore` call them with the data already
/// extracted.
enum ManualToc {
    static func nextManualId(in entries: [TocEntryRecord]) -> String {
        let maxExisting = entries.compactMap { entry -> Int? in
            guard entry.id.hasPrefix("manual-") else { return nil }
            return Int(entry.id.dropFirst("manual-".count))
        }.max() ?? 0
        return "manual-\(maxExisting + 1)"
    }

    /// An edit to an automatic entry creates a visible manual entry and
    /// keeps the original as a tombstone. This way a later regeneration
    /// cannot reintroduce the old title/level next to the edited version.
    static func changeLevel(id: String, to level: Int, entries: inout [TocEntryRecord]) {
        editEntry(id: id, entries: &entries) { $0.level = min(4, max(1, level)) }
    }

    static func rename(id: String, to title: String, entries: inout [TocEntryRecord]) {
        editEntry(id: id, entries: &entries) { $0.title = title }
    }

    /// A manually created entry also stays as a tombstone when it is
    /// removed. It is invisible, but keeps the user's decision stable if a
    /// future generation produces an identical entry.
    static func remove(id: String, entries: inout [TocEntryRecord]) {
        guard let index = index(of: id, in: entries) else { return }
        entries[index].origin = .manual
        entries[index].removed = true
    }

    /// With the same id, the VISIBLE record wins. A `documento.json` saved
    /// before this rule can contain a tombstone and a shown entry with the
    /// same "gen-N" (see `merge`): "Rename"/"Remove"/"Change level" must act
    /// on the entry the user sees, not on the tombstone that precedes it.
    private static func index(of id: String, in entries: [TocEntryRecord]) -> Int? {
        entries.firstIndex(where: { $0.id == id && $0.removed != true }) ?? entries.firstIndex(where: { $0.id == id })
    }

    private static func editEntry(
        id: String,
        entries: inout [TocEntryRecord],
        mutate: (inout TocEntryRecord) -> Void
    ) {
        guard let index = index(of: id, in: entries) else { return }
        if entries[index].origin != .manual {
            var tombstone = entries[index]
            tombstone.origin = .manual
            tombstone.removed = true
            entries[index].id = nextManualId(in: entries)
            entries[index].origin = .manual
            entries[index].removed = nil
            mutate(&entries[index])
            entries.append(tombstone)
        } else {
            mutate(&entries[index])
        }
    }

    /// "newlines → spaces, end-of-line hyphenation joined, trimmed". The
    /// hyphenation dash is recognized as "-" followed by a newline (the same
    /// signal `HyphenationJoiner` uses for body text; on a short selection
    /// nothing else is needed here).
    static func cleanTitle(_ raw: String) -> String {
        let hyphenJoined = raw.replacingOccurrences(of: "-\n", with: "").replacingOccurrences(of: "-\r\n", with: "")
        let spaced = hyphenJoined.components(separatedBy: .newlines).joined(separator: " ")
        let collapsed = spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Two entries on the SAME heading line (one generated, matched to the
    /// `Heading` with `TocHeadingMatch`, and one manual created from a
    /// selection of that line) have `pageY` values equal up to fractions of a
    /// point (`Heading.rect.maxY` versus `PDFSelection.bounds.maxY`,
    /// `ManualSelectionResolver.pageY`). Within this distance they count as
    /// the "same point": two distinct heading lines are never that close (a
    /// text line is at least twice as tall).
    static let sameLineTolerance: Double = 3

    /// Document order shared by `sorted` and by `TocNavigation.ordered` (a
    /// single order for the tree shown and for the current entry): by page,
    /// then by **descending** `pageY` (unflipped PDF page space: higher y =
    /// closer to the start of the page) among entries that have one, arrival
    /// order on ties. Legacy entries without a position are treated as the
    /// start of the page and keep their arrival order among themselves: so a
    /// legacy T1 can stay the parent of a precise manual T2. Then every run
    /// of consecutive entries on the same page within `sameLineTolerance` of
    /// one another is reordered by ascending level (T1 before T2), then
    /// arrival order: it is the only order in which `indentDepths` nests the
    /// deeper entry under the other instead of showing it ABOVE the parent at
    /// depth 0. The first pass's comparison stays strict (no tolerance inside
    /// a comparator, which would not be an ordering); the tolerance lives
    /// only in the subsequent grouping, on entries already adjacent, with no
    /// fixed buckets and hence no edge cases between two buckets.
    static func documentOrder<T>(_ items: [T], page: (T) -> Int, pageY: (T) -> Double?, level: (T) -> Int) -> [T] {
        var ordered = items.enumerated().map { (offset: $0.offset, element: $0.element) }.sorted { lhs, rhs in
            let lhsPage = page(lhs.element), rhsPage = page(rhs.element)
            if lhsPage != rhsPage { return lhsPage < rhsPage }
            switch (pageY(lhs.element), pageY(rhs.element)) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?): return true
            case (_?, nil): return false
            default: return lhs.offset < rhs.offset
            }
        }
        var start = 0
        while start < ordered.count {
            var end = start + 1
            while end < ordered.count, page(ordered[end - 1].element) == page(ordered[end].element),
                  let previousY = pageY(ordered[end - 1].element), let nextY = pageY(ordered[end].element),
                  abs(previousY - nextY) <= sameLineTolerance {
                end += 1
            }
            if end - start > 1 {
                ordered[start ..< end].sort { lhs, rhs in
                    let lhsLevel = level(lhs.element), rhsLevel = level(rhs.element)
                    if lhsLevel != rhsLevel { return lhsLevel < rhsLevel }
                    return lhs.offset < rhs.offset
                }
            }
            start = end
        }
        return ordered.map(\.element)
    }

    static func sorted(_ entries: [TocEntryRecord]) -> [TocEntryRecord] {
        documentOrder(entries, page: { $0.page }, pageY: { $0.pageY }, level: { $0.level })
    }

    /// "Regenerate contents" (SPEC "keeps them and replaces only the
    /// automatic ones"): manual entries (added, changed, or removal
    /// tombstones, `origin == .manual`) always stay; the new automatic list
    /// replaces the old one. An automatic entry that duplicates a manual one
    /// (same page, same title ignoring case) is discarded in favor of the
    /// manual one.
    static func merge(manual: [TocEntryRecord], newAuto: [TocEntryRecord]) -> [TocEntryRecord] {
        let manualKeys = Set(manual.map { dedupeKey(page: $0.page, title: $0.title) })
        var keptAuto = newAuto.filter { $0.origin != .manual && !manualKeys.contains(dedupeKey(page: $0.page, title: $0.title)) }
        // Generated ids are positional ("gen-N", SPEC §7.4) and a tombstone/
        // an edited entry keeps its ORIGINAL id, so after "Regenerate
        // contents" the same "gen-N" can come back with a different title and
        // coexist with the tombstone: two records with the same id, and
        // "Rename"/"Remove"/"Change level" (`firstIndex(where:)`) used to land
        // on the invisible tombstone instead of the shown entry. An
        // automatic id already taken by the manual layer gets a suffix:
        // generated ids are not stable between one generation and the next
        // anyway, so nobody can depend on the value.
        var usedIds = Set(manual.map(\.id))
        for index in keptAuto.indices {
            var candidate = keptAuto[index].id
            var attempt = 1
            while usedIds.contains(candidate) {
                candidate = "\(keptAuto[index].id)-r\(attempt)"
                attempt += 1
            }
            keptAuto[index].id = candidate
            usedIds.insert(candidate)
        }
        return sorted(manual + keptAuto)
    }

    private static func dedupeKey(page: Int, title: String) -> String {
        "\(page)|\(TermRegistry.normalize(title))"
    }

    /// After the list has been REPLACED (contents regenerated: the "gen-N"
    /// ids change place), which new id corresponds to each old id: the new
    /// entry with the same page and the same title (the same key as the
    /// deduplication); failing that, the same id ONLY for a manual entry
    /// (its ids are stable; a surviving "gen-N" with another title is a
    /// different entry, not the same one); absent if the entry no longer
    /// exists. `DocumentModel` uses it to carry along the collapsed state and
    /// the pin instead of leaving them on ids that now point to another entry
    /// or to none.
    static func idRemap(from old: [TocEntry], to new: [TocEntry]) -> [String: String] {
        let newIds = Set(new.map(\.id))
        var newIdByKey: [String: String] = [:]
        for entry in new where newIdByKey[dedupeKey(page: entry.page, title: entry.title)] == nil {
            newIdByKey[dedupeKey(page: entry.page, title: entry.title)] = entry.id
        }
        var remap: [String: String] = [:]
        for entry in old {
            if let matched = newIdByKey[dedupeKey(page: entry.page, title: entry.title)] {
                remap[entry.id] = matched
            } else if entry.isManual, newIds.contains(entry.id) {
                remap[entry.id] = entry.id
            }
        }
        return remap
    }

    /// Entries shown in the tree: a manual entry with `removed: true` is the
    /// record of a removal of an automatic entry (tombstone), never
    /// visible.
    static func visible(_ entries: [TocEntryRecord]) -> [TocEntryRecord] {
        entries.filter { $0.removed != true }
    }

    /// Indentation depth (0-based) for each entry, in the order already
    /// given by `sorted`/`visible` (SPEC "each level is indented more than
    /// the one above... an orphan level attaches to the nearest shallower
    /// one"): independent of the saved 1-4 `level` (which remains the real
    /// data, used for "Change level" and for chapter/section elsewhere); only
    /// the visual indentation is recomputed here, with a stack of the current
    /// levels.
    static func indentDepths(for entries: [TocEntryRecord]) -> [Int] {
        indentDepths(levels: entries.map(\.level))
    }

    /// Overload on `TocEntry` (a display struct, `ChaptersSidebar`): the same
    /// function, on the `level`s alone in order.
    static func indentDepths(levels: [Int]) -> [Int] {
        var openLevels: [Int] = []
        var depths: [Int] = []
        for level in levels {
            while let last = openLevels.last, last >= level { openLevels.removeLast() }
            openLevels.append(level)
            depths.append(openLevels.count - 1)
        }
        return depths
    }
}
