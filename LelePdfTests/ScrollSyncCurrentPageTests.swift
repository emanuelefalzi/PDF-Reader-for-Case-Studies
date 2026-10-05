import Foundation
import AppKit
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// Regression (SPEC §12 use case 12, M10 part B): while verifying search in
/// the "Chapter" scope live on the Merck case, with "Follow the PDF" on and
/// scrolling ONLY the right panel, the "Page N of M" bar stayed on the first
/// page and the "Chapter" search found 0 results for a term that was in fact
/// visible on screen (it worked in the "Whole PDF" scope, and worked again as
/// soon as the PDF itself was also scrolled directly). Cause:
/// `ScrollSyncCoordinator.drive(from: .panel)` scrolls the PDF side with
/// `DocumentSpace.scroll` (direct bounds on `NSClipView`, not
/// `PDFView.go(to:)`), under the re-entrancy guard
/// `isApplyingProgrammaticScroll`. That also suppresses the
/// `.PDFViewPageChanged` notification from which
/// `PDFReaderCoordinator.handlePageChanged` derives
/// `DocumentModel.currentPageIndex` (used both by the bar and by
/// `TocNavigation.chapterPageRange`, the "Chapter" scope of search).
/// Unlike the other `Sync/` tests, this one uses a real multi-page `PDFView`
/// (not a generic `NSView`): the bug depends precisely on the difference
/// between PDFKit's real notification and direct scrolling of the clip view,
/// so a real `PDFReaderBridge` is needed to observe it.
extension HeavyTestSuites {
@MainActor
@Suite("Sync: current page after panel-driven scrolling", .serialized)
struct ScrollSyncCurrentPageTests {
    private func makeModel(pageCount: Int) throws -> (model: DocumentModel, pdfWindow: NSWindow, panelWindow: NSWindow) {
        let sourceURL = try StoreFixtures.makeMultiPageTextPDF(pageCount: pageCount, fileName: "sync-page-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "sync-page-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        // NOT closed here: they go back to the caller and stay alive for the
        // whole test (panel-driven scrolling uses `pdfScrollView`/`panelSV`
        // throughout). The caller closes them at the end of the test.
        let pdfWindow = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        pdfWindow.isReleasedWhenClosed = false
        pdfWindow.contentView = pdfView
        pdfWindow.layoutIfNeeded()

        let bridge = PDFReaderBridge(pdfView: pdfView)
        model.readerBridge = bridge
        guard let pdfScrollView = bridge.enclosingScrollView else {
            Issue.record("PDFView without enclosingScrollView: cannot attach ScrollSyncCoordinator")
            return (model, pdfWindow, pdfWindow)
        }
        model.syncCoordinator.attachPDF(scrollView: pdfScrollView, model: model)

        // Panel: generic NSScrollView as in the rest of the `Sync/` suite
        // (the panel does not need a real PDFView).
        let panelDoc = FlippedContentView(frame: CGRect(x: 0, y: 0, width: 300, height: 800))
        let panelSV = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        panelSV.documentView = panelDoc
        let panelWindow = NSWindow(contentRect: panelSV.frame, styleMask: [.titled], backing: .buffered, defer: false)
        panelWindow.isReleasedWhenClosed = false
        panelWindow.contentView = panelSV
        panelWindow.layoutIfNeeded()
        model.syncCoordinator.attachPanel(scrollView: panelSV, model: model)

        let pdfDocHeight = DocumentSpace.documentHeight(pdfScrollView)
        // 1:1 mapping between the two spaces (same height), as in the
        // existing `ScrollSyncCoordinatorTests` tests: a single segment
        // covering the whole document.
        model.syncCoordinator.segments = [
            AlignmentSegment(id: "doc", pdfStart: 0, pdfHeight: pdfDocHeight, panelStart: 0, panelHeight: pdfDocHeight),
        ]
        model.followPDF = true

        return (model, pdfWindow, panelWindow)
    }

    private final class FlippedContentView: NSView {
        override var isFlipped: Bool { true }
    }

    @Test("scrolling only the panel with Follow the PDF on, currentPageIndex follows the moved PDF (it does not stay on the first page)")
    func currentPageIndexFollowsPanelDrivenScroll() throws {
        let (model, pdfWindow, panelWindow) = try makeModel(pageCount: 5)
        defer { closeTestWindow(pdfWindow) }
        defer { closeTestWindow(panelWindow) }
        #expect(model.currentPageIndex == 0)

        guard let panelSV = model.syncCoordinator.panelScrollViewForMeasurement else {
            Issue.record("panel not attached")
            return
        }

        // Scrolls only the panel almost to the bottom of the document (1:1
        // mapping, so it corresponds to a point near the last page): before
        // the fix, `model.currentPageIndex` stayed at 0 because the PDF
        // side's `.PDFViewPageChanged` notification, moved only as a side
        // effect of `drive`, is suppressed by the re-entrancy guard. After
        // the fix, `updateCurrentReadingPosition()` queries `PDFReaderBridge`
        // directly and updates the page.
        let maxPanelScroll = DocumentSpace.maxScrollTopDown(panelSV)
        DocumentSpace.scroll(panelSV, topDownTop: maxPanelScroll)

        #expect(model.currentPageIndex > 0, "currentPageIndex not updated after panel-driven scrolling (use case 12 regression)")
        #expect(model.currentReadingPageY != nil)

        _ = pdfWindow
        _ = panelWindow
    }
}
}
