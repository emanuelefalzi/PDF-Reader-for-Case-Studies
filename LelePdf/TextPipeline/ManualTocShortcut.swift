import Foundation

/// ⌘⌥1…4 (v2.3 §5.3, M7-2): the text selected in the PDF becomes a T1-T4
/// entry, with the SAME effect as the T1-T4 buttons of the selection bar
/// (the same `pageY`, the same hierarchy), unless the selected text is
/// already an entry of the contents, in which case the shortcut changes its
/// level instead of duplicating it. On a multi-selection it applies this
/// same rule to **every piece**, all at the same level, all inside the SAME
/// resulting array, so the caller (`DocumentModel`) records a single
/// before/after, hence a single ⌘Z entry for the whole operation. Pure: no
/// dependency on PDFKit, testable on its own.
enum ManualTocShortcut {
    /// An already resolved selection piece (page, cleaned title, vertical
    /// position); `DocumentModel` builds it from a `PDFSelection` with
    /// `ManualToc.cleanTitle`/`ManualSelectionResolver.pageY`.
    struct Piece: Sendable, Equatable {
        var page: Int
        var title: String
        var pageY: Double?
    }

    /// An existing entry "is" the same title if it has the same page and the
    /// same normalized title (case/spaces ignored): the same deduplication
    /// criterion already used by `ManualToc.merge`/"Regenerate contents"
    /// (`dedupeKey`), reused here to decide "add" vs "change level".
    /// Tombstones (`removed == true`) do not count: they are invisible, and a
    /// new T1-T4 on the same text must be able to reappear.
    static func apply(pieces: [Piece], level: Int, entries: [TocEntryRecord]) -> [TocEntryRecord] {
        var result = entries
        for piece in pieces {
            if let existing = result.first(where: {
                $0.removed != true && $0.page == piece.page && TermRegistry.normalize($0.title) == TermRegistry.normalize(piece.title)
            }) {
                // Already at the requested level: no change (avoids an empty
                // round of tombstones for a ⌘⌥N pressed twice by mistake).
                guard existing.level != level else { continue }
                ManualToc.changeLevel(id: existing.id, to: level, entries: &result)
            } else {
                let entry = TocEntryRecord(id: ManualToc.nextManualId(in: result), title: piece.title, level: level, page: piece.page, origin: .manual, pageY: piece.pageY)
                result.append(entry)
            }
        }
        return result
    }
}
