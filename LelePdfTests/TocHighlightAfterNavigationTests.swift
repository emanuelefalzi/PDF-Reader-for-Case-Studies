import Foundation
import AppKit
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// Reported bug: when a heading is clicked, which takes the reader to the
/// right place, the heading above it is highlighted in the menu. Uses a real
/// `PDFView`/`PDFReaderBridge` (not just `TocNavigation.currentEntry` in
/// isolation, as in `TocNavigationTests`): the real bug depends on the offset
/// between the navigation target (`TocHeadingDestination.topMargin`, 10pt
/// below the heading) and the reading position re-read right afterwards from
/// the real `PDFView` (`PDFReaderBridge.topVisiblePagePosition`), which a
/// synthetic `TocEntry` without a real PDF would never have reproduced.
extension HeavyTestSuites {
@MainActor
@Suite("Contents: highlight after a jump from a heading", .serialized)
struct TocHighlightAfterNavigationTests {
    private func entry(_ id: String, page: Int, pageY: Double, level: Int = 1) -> TocEntry {
        TocEntry(id: id, title: id, level: level, page: page, pageY: pageY)
    }

    /// Same scheme as `ScrollSyncCurrentPageTests.makeModel`: a real
    /// `PDFView` (not a generic `NSView`), `scaleFactor` fixed at 1 so page
    /// space and view space coincide 1:1; no need for the right panel, the
    /// contents highlight does not depend on it.
    private func makeModel(pageCount: Int = 1, pageSize: CGSize = CGSize(width: 300, height: 600)) throws -> (model: DocumentModel, window: NSWindow) {
        let sourceURL = try StoreFixtures.makeMultiPageTextPDF(pageCount: pageCount, pageSize: pageSize, fileName: "toc-highlight-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "toc-highlight-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1

        // The window is NOT closed here: it stays alive for the whole test
        // (`defer { closeTestWindow(window) }` in the caller).
        let window = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pdfView
        window.layoutIfNeeded()

        let bridge = PDFReaderBridge(pdfView: pdfView)
        model.readerBridge = bridge
        guard let pdfScrollView = bridge.enclosingScrollView else {
            Issue.record("PDFView without enclosingScrollView: cannot attach ScrollSyncCoordinator")
            return (model, window)
        }
        model.syncCoordinator.attachPDF(scrollView: pdfScrollView, model: model)

        return (model, window)
    }

    @Test("two headings on the same page: after the click the clicked one stays highlighted, not the one above")
    func twoTitlesSamePage() throws {
        let (model, window) = try makeModel()
        defer { closeTestWindow(window) }
        model.tocEntries = [entry("alto", page: 0, pageY: 500), entry("basso", page: 0, pageY: 200)]

        model.goToTocEntry(model.tocEntries[0])
        #expect(model.currentTocEntry?.id == "alto", "expected 'alto' right after the click, found \(model.currentTocEntry?.id ?? "nil")")

        model.goToTocEntry(model.tocEntries[1])
        #expect(model.currentTocEntry?.id == "basso", "expected 'basso' right after the click, found \(model.currentTocEntry?.id ?? "nil")")
    }

    @Test("three headings on the same page: each stays highlighted after its own click, in any order")
    func threeTitlesSamePage() throws {
        let (model, window) = try makeModel()
        defer { closeTestWindow(window) }
        model.tocEntries = [
            entry("t1", page: 0, pageY: 550),
            entry("t2", page: 0, pageY: 350),
            entry("t3", page: 0, pageY: 150),
        ]

        for target in model.tocEntries {
            model.goToTocEntry(target)
            #expect(model.currentTocEntry?.id == target.id, "expected '\(target.id)' right after the click, found \(model.currentTocEntry?.id ?? "nil")")
        }

        // Click again from bottom to top: the pin must not stay "stuck" to
        // the very first heading clicked.
        model.goToTocEntry(model.tocEntries[0])
        #expect(model.currentTocEntry?.id == "t1")
    }

    @Test("headings near the page edge (top and bottom): the click highlights the right one")
    func titlesNearPageEdges() throws {
        let (model, window) = try makeModel(pageSize: CGSize(width: 300, height: 600))
        defer { closeTestWindow(window) }
        model.tocEntries = [
            entry("cima", page: 0, pageY: 595), // 5pt from the top edge (600)
            entry("fondo", page: 0, pageY: 5), // 5pt from the bottom edge (0)
        ]

        model.goToTocEntry(model.tocEntries[0])
        #expect(model.currentTocEntry?.id == "cima", "expected 'cima' right after the click, found \(model.currentTocEntry?.id ?? "nil")")

        model.goToTocEntry(model.tocEntries[1])
        #expect(model.currentTocEntry?.id == "fondo", "expected 'fondo' right after the click, found \(model.currentTocEntry?.id ?? "nil")")
    }

    @Test("after the click, a real PDF scroll unpins and the highlight goes back to following the reading")
    func manualScrollAfterClickUnpinsHighlight() throws {
        let (model, window) = try makeModel()
        defer { closeTestWindow(window) }
        // Page 600pt, view 200pt: scrolling all the way down, the view's top
        // edge reaches pageY 200 at most (`pageHeight - viewportHeight`);
        // "secondo" must sit just below that threshold (with the tolerance)
        // so as to count as "just passed" at the end of the scroll, not
        // buried lower on the same page (unreachable from the top edge alone
        // without changing page).
        model.tocEntries = [entry("primo", page: 0, pageY: 550), entry("secondo", page: 0, pageY: 195)]

        model.goToTocEntry(model.tocEntries[0])
        #expect(model.currentTocEntry?.id == "primo")
        #expect(model.pinnedTocEntryID == "primo")

        guard let pdfScrollView = model.syncCoordinator.pdfScrollViewForMeasurement else {
            Issue.record("PDF not attached")
            return
        }
        // REAL scroll (outside `goToTocEntry`/`performGuardedNavigation`): the
        // scroll notification is not suppressed, like a real drag of the
        // scroll bar/trackpad.
        let maxScroll = DocumentSpace.maxScrollTopDown(pdfScrollView)
        DocumentSpace.scroll(pdfScrollView, topDownTop: maxScroll)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(model.pinnedTocEntryID == nil, "the pin should have been released on the first real scroll")
        let expected = TocNavigation.currentEntry(entries: model.tocEntries, page: model.currentPageIndex, pageY: model.currentReadingPageY)
        #expect(model.currentTocEntry?.id == expected?.id, "after unpinning the highlight must go back to the geometric computation")
        #expect(model.currentTocEntry?.id == "secondo", "scrolling to the bottom of the page the last heading passed is 'secondo'")
    }
}
}
