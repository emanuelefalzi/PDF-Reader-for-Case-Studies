import Foundation
import Testing
@testable import LelePdf

/// `TocNavigation.currentEntry` (reported problem: two headings on the same
/// page): the highlight in the Contents sidebar must follow the real reading
/// position on the current page, not always the deepest entry of the page.
@Suite("TocNavigation.currentEntry")
struct TocNavigationTests {
    private func entry(_ id: String, page: Int, pageY: Double? = nil, level: Int = 1) -> TocEntry {
        TocEntry(id: id, title: id, level: level, page: page, pageY: pageY)
    }

    @Test("without pageY (previous behavior): the deepest entry of the page reached")
    func fallsBackToDeepestOnReachedPageWithoutPageY() {
        let entries = [entry("cap1", page: 0, level: 1), entry("sez1", page: 3, level: 2), entry("cap2", page: 5, level: 1)]
        let current = TocNavigation.currentEntry(entries: entries, page: 4)
        #expect(current?.id == "sez1")
    }

    @Test("two headings on the same page: highlights the one just passed, not always the deepest")
    func twoHeadingsOnSamePagePicksTheOneJustPassed() {
        // Higher pageY = closer to the top of the page (read first).
        let entries = [entry("primo", page: 3, pageY: 700, level: 1), entry("secondo", page: 3, pageY: 400, level: 2)]

        // Reading just below "primo" but before "secondo": stays "primo".
        #expect(TocNavigation.currentEntry(entries: entries, page: 3, pageY: 650)?.id == "primo")
        // Reading just below "secondo": now it is "secondo", the most recent one passed.
        #expect(TocNavigation.currentEntry(entries: entries, page: 3, pageY: 350)?.id == "secondo")
    }

    @Test("a heading on the current page not yet reached (pageY below the reading) does not count")
    func headingNotYetReachedOnCurrentPageIsExcluded() {
        let entries = [entry("cap1", page: 0, level: 1), entry("nonRaggiunto", page: 3, pageY: 200, level: 2)]
        let current = TocNavigation.currentEntry(entries: entries, page: 3, pageY: 500)
        #expect(current?.id == "cap1")
    }

    @Test("no entry reached → nil")
    func noEntryReachedReturnsNil() {
        #expect(TocNavigation.currentEntry(entries: [entry("dopo", page: 5)], page: 0) == nil)
    }

    @Test("right after a jump the reading is topMargin above the clicked heading: it must still win, not the one above")
    func justNavigatedHeadingWinsDespiteNavigationMargin() {
        // Same geometry as the real bug: `TocHeadingDestination.point` brings
        // the reading position to `entry.pageY + topMargin`, not exactly to
        // `entry.pageY`; the comparison must tolerate this offset (see
        // `TocNavigation.readingPositionTolerance`).
        let entries = [entry("sopra", page: 3, pageY: 700, level: 1), entry("cliccato", page: 3, pageY: 400, level: 2)]
        let readingPageYAfterJump = 400 + TocNavigation.readingPositionTolerance
        #expect(TocNavigation.currentEntry(entries: entries, page: 3, pageY: readingPageYAfterJump)?.id == "cliccato")
    }

    @Test("beyond the navigation margin's tolerance, the entry above wins again")
    func toleranceDoesNotExtendBeyondNavigationMargin() {
        let entries = [entry("sopra", page: 3, pageY: 700, level: 1), entry("cliccato", page: 3, pageY: 400, level: 2)]
        let wellPastTolerance = 400 + TocNavigation.readingPositionTolerance + 50
        #expect(TocNavigation.currentEntry(entries: entries, page: 3, pageY: wellPastTolerance)?.id == "sopra")
    }
}
