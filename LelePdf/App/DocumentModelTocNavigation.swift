import Foundation

/// Navigation from the contents and reading position for the Chapters
/// sidebar (fix for a bug reported by the user): kept in a file separate
/// from `DocumentModel.swift` to keep files short, like
/// `DocumentModelManualToc.swift`.
@MainActor
extension DocumentModel {
    /// Click on a contents entry: with a known `pageY` (a native/generated
    /// entry matched to a detected heading, or a manual one) it brings that
    /// heading to the top of the screen with a single navigation call,
    /// guarded against bounce-back with `ScrollSyncCoordinator`; without
    /// `pageY` (no match found, old contents) it falls back to the page jump
    /// alone, so that it "keeps working" as the report asked.
    func goToTocEntry(_ entry: TocEntry) {
        // Bug "the heading above gets highlighted": the clicked entry is the
        // "real" entry from the start, regardless of where exactly the reading
        // position falls after the jump (`currentTocEntry` below prefers it to
        // the geometric computation). It stays until the user really scrolls
        // again (`ScrollSyncCoordinator.handleScrolled`).
        pinnedTocEntryID = entry.id
        guard let pageY = entry.pageY else {
            // The page-only jump also goes under the guard: `PDFView.go(to:)` posts
            // the scroll notification synchronously, and without the guard
            // `handleScrolled` took it for a REAL scroll and released the pin just
            // set. With two entries without `pageY` on the same page (built-in
            // contents without a destination point, generated without a match) the
            // LAST one on the page stayed highlighted, not the clicked one, the same
            // symptom as the "wrong heading highlighted" bug.
            syncCoordinator.performGuardedNavigation {
                readerBridge?.goToPage(entry.page)
            }
            updateCurrentReadingPosition()
            syncCoordinator.followAfterNavigation(side: .pdf)
            return
        }
        syncCoordinator.performGuardedNavigation {
            readerBridge?.goToHeading(page: entry.page, pageY: pageY)
        }
        // The resulting scroll notification was suppressed by the guard above:
        // update the reading position here, otherwise the highlight in the
        // Chapters sidebar would stay the one from before the jump until the
        // next manual scroll.
        updateCurrentReadingPosition()
        // And bring the panel along with the PDF (a single `drive`, with
        // "Follow the PDF" on); the guard above suppresses that one too.
        syncCoordinator.followAfterNavigation(side: .pdf)
    }

    /// Called by `ScrollSyncCoordinator.handleScrolled` on every REAL
    /// (non-programmatic) scroll of the PDF or the panel; it releases the
    /// "pin" set by `goToTocEntry`, so the highlight goes back to following
    /// the reading position as during normal manual scrolling.
    func clearPinnedTocEntry() {
        pinnedTocEntryID = nil
    }

    /// Entry to highlight in the Chapters sidebar: the one just clicked if
    /// still "pinned" (and still present in the contents), otherwise the one
    /// computed from the real reading position (`TocNavigation.currentEntry`).
    /// Single source of truth, used by both `ChaptersSidebar` and the tests,
    /// with no duplicated logic.
    var currentTocEntry: TocEntry? {
        let resolved: TocEntry? = if let pinnedTocEntryID, let pinned = tocEntries.first(where: { $0.id == pinnedTocEntryID }) {
            pinned
        } else {
            TocNavigation.currentEntry(entries: tocEntries, page: currentPageIndex, pageY: currentReadingPageY)
        }
        // If the reading point is inside a collapsed entry, its nearest visible
        // ancestor is highlighted: the same rule as the pin above, only
        // redirected to the nearest visible ancestor when the real entry is
        // hidden.
        guard !collapsedTocEntryIds.isEmpty, let resolved,
              let index = tocEntries.firstIndex(where: { $0.id == resolved.id }) else { return resolved }
        let depths = ManualToc.indentDepths(levels: tocEntries.map(\.level))
        let visible = TocCollapse.visibleIndices(ids: tocEntries.map(\.id), depths: depths, collapsed: collapsedTocEntryIds)
        guard let ancestorIndex = TocCollapse.nearestVisibleAncestor(of: index, depths: depths, visible: visible) else { return resolved }
        return tocEntries[ancestorIndex]
    }

    /// Updated on every scroll of the PDF (`ScrollSyncCoordinator`, not just
    /// on page changes): the Chapters sidebar thus highlights the entry
    /// closest to the real reading position, not just to the page (bug: two
    /// headings on the same page always highlighted the same one, regardless
    /// of where one had scrolled).
    ///
    /// Also updates `currentPageIndex` by querying `PDFView` directly,
    /// instead of waiting for PDFKit's `.PDFViewPageChanged` notification
    /// (`PDFReaderCoordinator.handlePageChanged`): that notification does not
    /// arrive reliably when it is the right panel that carries the PDF along
    /// (`ScrollSyncCoordinator.drive(from: .panel)`, which scrolls
    /// `NSClipView` directly with `DocumentSpace.scroll`, not with
    /// `PDFView.go(to:)`). Found by checking use case 12 live (SPEC §12):
    /// with "Follow the PDF" on, scrolling only the right panel left the
    /// "Page N of M" bar still and the search in "Chapter" scope therefore
    /// stayed anchored to the old page, finding 0 results for a term that
    /// was actually visible on screen.
    func updateCurrentReadingPosition() {
        PerfProbe.measure("model.readingPosition") {
            guard let position = readerBridge?.topVisiblePagePosition() else { return }
            // `@Observable` notifies observers on EVERY assignment, even with the
            // same value: rewriting `currentPageIndex` on every scroll tick
            // re-evaluated every built thumbnail (`ThumbnailRow.body`), the "Page N
            // of M" bar and whoever else reads it, without the page having changed.
            if currentReadingPageY != position.pageY { currentReadingPageY = position.pageY }
            if currentPageIndex != position.page { currentPageIndex = position.page }
        }
    }
}
