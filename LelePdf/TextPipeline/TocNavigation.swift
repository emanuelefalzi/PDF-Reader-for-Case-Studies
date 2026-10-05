import Foundation

/// Pure functions on the contents: the chapter scope for search (SPEC §5.10)
/// and the "Ch. › section" path for the right panel (SPEC §5.6) and for
/// highlighting the current section in the sidebar (SPEC §5.3).
enum TocNavigation {
    /// The current chapter is the level-1 entry with the highest page not
    /// beyond `page`, up to the next level-1 entry (excluded) or the end of
    /// the document. `nil` if there are no level-1 entries.
    static func chapterPageRange(entries: [TocEntry], page: Int, pageCount: Int) -> ClosedRange<Int>? {
        let chapters = entries.filter { $0.level == 1 }.sorted { $0.page < $1.page }
        guard !chapters.isEmpty else { return nil }

        guard let currentIndex = chapters.lastIndex(where: { $0.page <= page }) else {
            // The page is before the first chapter (for example the cover/
            // contents): the "chapter" scope is everything that precedes the
            // first chapter.
            let end = max(0, chapters[0].page - 1)
            return 0...end
        }

        let start = chapters[currentIndex].page
        let end = currentIndex + 1 < chapters.count ? chapters[currentIndex + 1].page - 1 : pageCount - 1
        return start...max(start, end)
    }

    /// "Ch. 4 › 4.1 Notion of obligation", for the right panel's header and
    /// the highlighting in the sidebar. `nil` without a contents.
    static func breadcrumb(entries: [TocEntry], page: Int) -> String? {
        var path: [TocEntry] = []
        for entry in ordered(entries) where entry.page <= page {
            while let last = path.last, last.level >= entry.level { path.removeLast() }
            path.append(entry)
        }
        return path.isEmpty ? nil : path.map(\.title).joined(separator: " › ")
    }

    /// The same value as `TocHeadingDestination.topMargin`
    /// (`Reader/TocHeadingDestination.swift`): the margin with which
    /// `goToHeading` brings a heading 8-12 pt below the top edge of the
    /// screen instead of sticking it exactly (SPEC). Without this tolerance,
    /// the reading position read right after a jump
    /// (`PDFReaderBridge.topVisiblePagePosition`, the real top edge) is
    /// `entry.pageY + margin`: the strict comparison `entryPageY >= pageY`
    /// excluded exactly the entry just reached (its `pageY` sits 10pt BELOW
    /// that position) and made the previous entry on the same page win (a
    /// reported bug: the heading above was highlighted). The two files do not
    /// share a type so as to stay each in its own layer (`TextPipeline` pure,
    /// without CoreGraphics); they are kept in sync by hand, with a test that
    /// ties the two values together (`TocNavigationTests`).
    static let readingPositionTolerance: Double = 10

    /// The contents entry just passed by the reading position, in document
    /// order (page, then top to bottom): used to highlight the current row in
    /// the sidebar. `pageY` is the position (page space, y upward) at the top
    /// of the visible part of page `page`; with `nil`, or for entries with no
    /// `pageY` of their own, only the page counts.
    static func currentEntry(entries: [TocEntry], page: Int, pageY: Double? = nil) -> TocEntry? {
        let entriesInOrder = ordered(entries)
        guard let pageY else { return entriesInOrder.last { $0.page <= page } }

        let onCurrentPage = entriesInOrder.filter { $0.page == page }
        // If at least one positioned entry has really been passed, the one
        // closest to the reading line must win over legacy entries with no
        // `pageY`. The first resolution of the merge used a simple
        // `last(where:)`: an entry with no position, ordered after the precise
        // one, could therefore stay highlighted for the whole page.
        if let positioned = onCurrentPage.last(where: {
            guard let entryPageY = $0.pageY else { return false }
            return entryPageY >= pageY - readingPositionTolerance
        }) {
            return positioned
        }
        // No precise position reached: it keeps the M7 fallback for old/
        // unmatched contents; otherwise it stays on the nearest previous
        // page.
        return onCurrentPage.last(where: { $0.pageY == nil })
            ?? entriesInOrder.last(where: { $0.page < page })
    }

    /// The same order as `ManualToc.sorted` (`ManualToc.documentOrder`: a
    /// single order for the tree shown and for the current entry, so that on
    /// a tie of line the highlighted entry is the one the tree shows last). A
    /// legacy entry counts as the start of the page: besides providing the
    /// fallback before the first precise heading, it stays ahead of the
    /// page's manual T2/T3 and preserves their M7 hierarchy.
    private static func ordered(_ entries: [TocEntry]) -> [TocEntry] {
        ManualToc.documentOrder(entries, page: { $0.page }, pageY: { $0.pageY }, level: { $0.level })
    }
}
