import Foundation
import Testing
@testable import LelePdf

/// Pure mapping of the right panel (M5b deliverable 7 "view-model
/// mapping: segments → rows, labels, placeholder min height, pill text,
/// dots full/half").
@Suite("RewriteViewModel")
struct RewriteViewModelTests {
    @Test("segments become rows in the same order, with stable ids")
    func segmentsToRows() {
        let segments: [AnalysisController.DocumentSegment] = [
            .heading(title: "Capitolo 1", level: 1, page: 0),
            .block(blockId: "b1"),
            .exhibit(label: "Exhibit 2", page: 5),
        ]
        let rows = RewriteViewModel.rows(from: segments)
        #expect(rows.count == 3)
        guard case .heading(_, let title, let level, let page) = rows[0] else { Issue.record("row 0 is not a heading"); return }
        #expect(title == "Capitolo 1" && level == 1 && page == 0)
        guard case .block(_, let blockId) = rows[1] else { Issue.record("row 1 is not a block"); return }
        #expect(blockId == "b1")
        guard case .exhibit(_, let label, let exPage) = rows[2] else { Issue.record("row 2 is not an Exhibit"); return }
        #expect(label == "Exhibit 2" && exPage == 5)
    }

    @Test("orphaned analyses are appended after the normal rows")
    func mergedRowsAppendsOrphans() {
        let segments: [AnalysisController.DocumentSegment] = [.block(blockId: "b1")]
        let orphans = [OrphanBlock(blockId: "old1", page: 3)]
        let rows = RewriteViewModel.mergedRows(segments: segments, orphans: orphans)
        #expect(rows.count == 2)
        guard case .orphan(_, let blockId, let page) = rows[1] else { Issue.record("last row is not an orphan"); return }
        #expect(blockId == "old1" && page == 3)
    }

    @Test("the minimum height of a placeholder is 44pt (SPEC §5.6)")
    func placeholderMinHeight() {
        #expect(RewriteViewModel.placeholderMinHeight == 44)
    }

    @Test("the queue label shows the position")
    func queuedLabel() {
        #expect(RewriteViewModel.queuedLabel(position: 2) == "Queued (2)")
    }

    @Test("the 'running' label includes the block's human-readable label")
    func runningLabel() {
        #expect(RewriteViewModel.runningLabel(humanBlockLabel: "3.2") == "Claude is analyzing 3.2")
    }

    @Test("the ETA never shows negative seconds")
    func etaLabelNeverNegative() {
        #expect(RewriteViewModel.etaLabel(remainingSeconds: -5) == "about 1 s")
        #expect(RewriteViewModel.etaLabel(remainingSeconds: 40) == "about 40 s")
        #expect(RewriteViewModel.etaLabel(remainingSeconds: 125) == "about 2 min")
    }

    @Test("the placeholder label shows the 1-based page")
    func placeholderLabel() {
        #expect(RewriteViewModel.placeholderLabel(page: 11) == "Not analyzed yet \u{b7} p. 12")
    }

    @Test("the Exhibit label includes the ↗ link marker")
    func exhibitLabel() {
        #expect(RewriteViewModel.exhibitLabel(label: "Exhibit 5", page: 18) == "Exhibit 5 · p. 19 ↗")
    }

    @Test("full dot only if all blocks touching the page are analyzed")
    func pageDotFull() {
        #expect(PageAnalysisStatus.compute(analyzedCount: 2, totalTouching: 2) == .full)
    }

    @Test("half dot if only some blocks are analyzed")
    func pageDotPartial() {
        #expect(PageAnalysisStatus.compute(analyzedCount: 1, totalTouching: 2) == .partial)
    }

    @Test("no dot if zero blocks are analyzed or no block touches the page")
    func pageDotNone() {
        #expect(PageAnalysisStatus.compute(analyzedCount: 0, totalTouching: 3) == .none)
        #expect(PageAnalysisStatus.compute(analyzedCount: 0, totalTouching: 0) == .none)
    }
}
