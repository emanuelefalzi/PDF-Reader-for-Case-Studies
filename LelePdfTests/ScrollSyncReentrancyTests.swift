import Foundation
import AppKit
import Testing
@testable import LelePdf

/// Regression (SPEC §5.8, M6): the measurement run crashed the verification
/// app with a stack overflow ("Thread stack size exceeded due to excessive
/// recursion"). Confirmed traceback: `NSClipView.setBoundsOrigin` posts
/// `boundsDidChangeNotification` more than once and re-entrantly within the
/// same call (once directly, a second time via
/// `_selfBoundsChanged`/`translateOriginToPoint:`, both BEFORE
/// `setBoundsOrigin` returns). The previous guard (`suppressPDFEcho`/
/// `suppressPanelEcho`, a flag consumed by the FIRST notification of each
/// side) left the second re-entrant notification free to restart as if it
/// were a real gesture: an infinite bounce between the two `NSScrollView`s
/// (`ScrollSyncCoordinator.drive` → `DocumentSpace.scroll` → notification →
/// the opposite side → `drive` → ... never stopping) until the stack was
/// exhausted. This AppKit behavior only appears with the views inside a real
/// `NSWindow` (the earlier test, `ScrollSyncCoordinatorTests`, uses
/// `NSScrollView`s outside a window and did not reproduce it), hence a
/// dedicated test file with a real window instead of just adding another
/// case to the existing one.
///
/// Fixed with a single real re-entrancy guard
/// (`isApplyingProgrammaticScroll`, not two "consume on that side's next
/// notification" flags): while a `DocumentSpace.scroll` called by us is in
/// progress, ANY scroll notification, on either side, once or more, is
/// ignored. This test counts the notifications observed independently of the
/// coordinator (so as not to depend on its own internal counters, which would
/// be accomplices of a possible regression) and checks that they stay small
/// and bounded: if the fix were to break, this test exhausts the stack and
/// fails the whole suite instead of passing unnoticed.
extension HeavyTestSuites {
@MainActor
@Suite("Sync: ScrollSyncCoordinator (re-entrancy regression)", .serialized)
struct ScrollSyncReentrancyTests {
    private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per la rientranza.", fileName: "sync-reentrancy-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "sync-reentrancy-test")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }

    /// Scroll view inside a real window (not merely instantiated on its own,
    /// as in the rest of the suite): needed because the double re-entrant
    /// notification of `NSClipView.setBoundsOrigin` observed in the real crash
    /// depends on the view actually belonging to a window hierarchy.
    private func windowedScrollView(documentHeight: CGFloat, viewportHeight: CGFloat) -> (window: NSWindow, scrollView: NSScrollView) {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: viewportHeight))
        let doc = FlippedDoc(frame: CGRect(x: 0, y: 0, width: 300, height: documentHeight))
        scrollView.documentView = doc
        scrollView.contentView.setFrameSize(NSSize(width: 300, height: viewportHeight))
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        // NO `closeTestWindow` here (it was inserted automatically at first,
        // then removed), for two reasons, not just one: (1) the window goes
        // back to the caller and must stay alive for the whole test (the real
        // bounce depends on belonging to a real window hierarchy, see the
        // comment above); closing it here detaches it IMMEDIATELY, before the
        // test triggers the scrolling. (2) the paragraph below, written while
        // hunting the original crash of this file, warns specifically against
        // AppKit's closing machinery for THIS window, not just `close()`, a
        // caution that also applies to the `orderOut`/`contentView = nil`
        // sequence of `closeTestWindow`. Real crash found while resuming this
        // work: a `close()` call would release the window by itself (the
        // default behavior for an `NSWindow` created in code, not from a nib)
        // while this test's `let window` already keeps it alive with ARC: a
        // double release, `objc_release` inside
        // `AutoreleasePoolPage::releaseUntil` at the end of the test. `false`
        // lets ARC alone decide when the window goes away.
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.layoutIfNeeded()
        return (window, scrollView)
    }

    @Test("scrolling inside a real window does not bounce infinitely between the two sides (no stack overflow)")
    func noInfiniteBounceInsideRealWindow() throws {
        let model = try makeModel()
        model.followPDF = true
        let coordinator = model.syncCoordinator
        let (pdfWindow, pdfSV) = windowedScrollView(documentHeight: 1000, viewportHeight: 300)
        let (panelWindow, panelSV) = windowedScrollView(documentHeight: 400, viewportHeight: 150)
        coordinator.attachPDF(scrollView: pdfSV, model: model)
        coordinator.attachPanel(scrollView: panelSV, model: model)
        coordinator.segments = [AlignmentSegment(id: "b1", pdfStart: 0, pdfHeight: 1000, panelStart: 0, panelHeight: 400)]

        // Counters independent of the coordinator: they observe the same
        // notifications it observes, but share none of its internal state (so
        // they are not "accomplices" of a possible regression).
        var pdfNotificationCount = 0
        var panelNotificationCount = 0
        let pdfCounterObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: pdfSV.contentView, queue: .main) { _ in pdfNotificationCount += 1 }
        let panelCounterObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: panelSV.contentView, queue: .main) { _ in panelNotificationCount += 1 }
        defer {
            NotificationCenter.default.removeObserver(pdfCounterObserver)
            NotificationCenter.default.removeObserver(panelCounterObserver)
        }

        // The same kind of direct call used by `SyncMeasurementRunner` to
        // simulate a scroll (it bypasses the coordinator and triggers its
        // notifications as a real gesture would).
        DocumentSpace.scroll(pdfSV, topDownTop: 300)

        // If the test gets here, there was no stack overflow: the re-entrancy
        // guard stopped the bounce. It also checks that the panel moved only
        // once (not repeatedly) and that the number of observed notifications
        // stays small and bounded (even a partial, non-infinite bounce would
        // still grow these counters well beyond a single scroll with echo).
        // readingY = 300 + 0.3*300 = 390 → fraction 390/1000 = 0.39 in the segment
        // → target = 0 + 0.39*400 - 0.3*150 = 156 - 45 = 111.
        #expect(DocumentSpace.visibleTopDown(panelSV)?.top == 111)
        #expect(pdfNotificationCount <= 3, "too many PDF notifications: \(pdfNotificationCount), possible bounce")
        #expect(panelNotificationCount <= 3, "too many panel notifications: \(panelNotificationCount), possible bounce")

        // No explicit `close()`: a real double-release crash
        // (`objc_release` inside `AutoreleasePoolPage::releaseUntil`) showed
        // up several times during the whole suite after this test was added.
        // `isReleasedWhenClosed = false` prevents it for the direct case, but
        // `close()` still triggers internal AppKit machinery (notifications,
        // removal from the hierarchy) that a test which only has to verify
        // scroll geometry does not need: letting ARC deallocate the windows at
        // the end of the function, as `RewriteScrollHostTests` already does,
        // avoids that machinery altogether.
        _ = pdfWindow
        _ = panelWindow
    }
}
}
