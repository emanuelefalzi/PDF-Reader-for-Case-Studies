import Foundation
import AppKit
import Testing
@testable import LelePdf

/// Regression test for the memory loop in the scroll alignment work
/// (F6-ALL). Its first version started a SYNCHRONOUS `drive` from every
/// segment rebuild and every `frameDidChangeNotification` of the panel's clip
/// view; `drive` from the panel side scrolls the PDF and updates the reading
/// position, which changes the height of `ContinueButtonRow`, which changes
/// the panel's frame and rectangles, which re-drive... an endless cycle,
/// inside `layoutSubtreeIfNeeded` and never returning to the run loop (31 and
/// 38 GB of footprint in ~75 s, the Mac locked up twice on 2026-09-21).
///
/// Here, with two `NSScrollView`s in real windows (like
/// `ScrollSyncReentrancyTests`) and synthetic segments, the fix's contract is
/// verified: (1) a redrive request moves nothing synchronously and ten
/// requests in the same turn make ONE `drive`; (2) a panel frame oscillation
/// that continues on every turn dies out within the per-gesture budget and
/// the run ends; (3) a real gesture reopens the budget; (4) without a gesture
/// or with "Follow the PDF" off nothing starts. Notifications are counted by
/// an observer independent of the coordinator, not by its counters (which
/// would be accomplices of a regression).
@MainActor
@Suite("Sync: automatic drives deferred and bounded (memory loop regression)", .serialized)
struct ScrollSyncRedriveTests {
    private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per le drive rimandate.", fileName: "sync-redrive-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "sync-redrive-test")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }

    /// See `ScrollSyncReentrancyTests.windowedScrollView`: the double
    /// re-entrant `setBoundsOrigin` notification only appears inside a real
    /// window; `isReleasedWhenClosed = false` avoids the double release.
    private func windowedScrollView(documentHeight: CGFloat, viewportHeight: CGFloat) -> (window: NSWindow, scrollView: NSScrollView) {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: viewportHeight))
        let doc = FlippedDoc(frame: CGRect(x: 0, y: 0, width: 300, height: documentHeight))
        scrollView.documentView = doc
        scrollView.contentView.setFrameSize(NSSize(width: 300, height: viewportHeight))
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.layoutIfNeeded()
        return (window, scrollView)
    }

    private struct Fixture {
        let model: DocumentModel
        let coordinator: ScrollSyncCoordinator
        let pdfWindow: NSWindow
        let panelWindow: NSWindow
        let pdfSV: NSScrollView
        let panelSV: NSScrollView
    }

    /// PDF 1000 pt in a 300 window, panel 1000 pt in 150: without a shared
    /// window the reading line is 30% of each side (90 and 45 pt), so the
    /// panel's target for a PDF top `t` is `t + 90 − 45`.
    private func makeFixture() throws -> Fixture {
        let model = try makeModel()
        model.followPDF = true
        let coordinator = model.syncCoordinator
        let (pdfWindow, pdfSV) = windowedScrollView(documentHeight: 1000, viewportHeight: 300)
        let (panelWindow, panelSV) = windowedScrollView(documentHeight: 1000, viewportHeight: 150)
        coordinator.attachPDF(scrollView: pdfSV, model: model)
        coordinator.attachPanel(scrollView: panelSV, model: model)
        coordinator.segments = [AlignmentSegment(id: "b1", pdfStart: 0, pdfHeight: 1000, panelStart: 0, panelHeight: 1000)]
        return Fixture(model: model, coordinator: coordinator, pdfWindow: pdfWindow, panelWindow: panelWindow, pdfSV: pdfSV, panelSV: panelSV)
    }

    private func panelTop(_ f: Fixture) -> CGFloat { DocumentSpace.visibleTopDown(f.panelSV)?.top ?? -1 }

    /// Lets the run loop turn: the deferred `drive`s
    /// (`DispatchQueue.main.async`) run here.
    private func turn() async throws {
        try await Task.sleep(for: .milliseconds(15))
    }

    @Test("a redrive request moves nothing synchronously; ten requests in the same turn make a single drive")
    func redriveIsDeferredAndCoalesced() async throws {
        let f = try makeFixture()
        // Real gesture: PDF at 300 → panel at 345.
        DocumentSpace.scroll(f.pdfSV, topDownTop: 300)
        #expect(abs(panelTop(f) - 345) < 0.5)
        // The PDF moves under the guard (like a navigation or a measurement):
        // the panel does not follow on its own.
        f.coordinator.performGuardedNavigation { DocumentSpace.scroll(f.pdfSV, topDownTop: 600) }
        #expect(abs(panelTop(f) - 345) < 0.5)
        for _ in 0 ..< 10 { f.coordinator.scheduleRedrive() }
        #expect(abs(panelTop(f) - 345) < 0.5, "no synchronous drive")
        #expect(f.coordinator.automaticRedriveCount == 0)
        try await turn()
        #expect(abs(panelTop(f) - 645) < 0.5, "after one run-loop turn the panel is at the target for the PDF at 600")
        #expect(f.coordinator.automaticRedriveCount == 1, "ten requests in the same turn = one drive")
        #expect(f.coordinator.automaticRedriveBudget == ScrollSyncCoordinator.maxAutomaticRedrivesPerGesture - 1)
        _ = f.pdfWindow
        _ = f.panelWindow
    }

    @Test("a panel frame change on every turn (ring (b) of the loop) dies out within the per-gesture budget, the run ends, a real gesture reopens the budget")
    func frameOscillationStopsWithinBudget() async throws {
        let f = try makeFixture()
        var panelNotificationCount = 0
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: f.panelSV.contentView, queue: .main) { _ in panelNotificationCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        DocumentSpace.scroll(f.pdfSV, topDownTop: 300)
        #expect(abs(panelTop(f) - 345) < 0.5)
        let afterGesture = panelNotificationCount

        // 200 turns: on each turn the panel clip view's frame changes height
        // (150 ↔ 160, as a header appearing and disappearing would): each
        // change posts `frameDidChangeNotification` and asks for a redrive;
        // the target changes by 3 pt each time, so every granted drive really
        // scrolls. Without a budget it would never end.
        let budget = ScrollSyncCoordinator.maxAutomaticRedrivesPerGesture
        for i in 0 ..< 200 {
            f.panelSV.contentView.setFrameSize(NSSize(width: 300, height: i % 2 == 0 ? 160 : 150))
            try await turn()
        }
        #expect(f.coordinator.automaticRedriveCount == budget, "automatic drives executed: \(f.coordinator.automaticRedriveCount), expected exactly \(budget)")
        #expect(f.coordinator.automaticRedriveBudget == 0)
        #expect(f.coordinator.automaticRedriveBudgetExhaustedCount > 0, "the budget must have been exhausted")
        #expect(panelNotificationCount - afterGesture <= budget * 3, "too many panel notifications: \(panelNotificationCount - afterGesture)")

        // A real gesture reopens the budget: the next frame change redrives
        // again, once.
        DocumentSpace.scroll(f.pdfSV, topDownTop: 320)
        #expect(f.coordinator.automaticRedriveBudget == budget)
        f.panelSV.contentView.setFrameSize(NSSize(width: 300, height: 170))
        try await turn()
        #expect(f.coordinator.automaticRedriveCount == budget + 1)
        _ = f.pdfWindow
        _ = f.panelWindow
    }

    @Test("without a previous gesture, or with 'Follow the PDF' off, a redrive does not start")
    func noRedriveWithoutGestureOrFollow() async throws {
        let f = try makeFixture()
        f.coordinator.scheduleRedrive()
        try await turn()
        #expect(f.coordinator.automaticRedriveCount == 0, "no side moved by the user: nothing to redrive")
        DocumentSpace.scroll(f.pdfSV, topDownTop: 300)
        f.model.followPDF = false
        f.coordinator.performGuardedNavigation { DocumentSpace.scroll(f.pdfSV, topDownTop: 600) }
        f.coordinator.scheduleRedrive()
        try await turn()
        #expect(f.coordinator.automaticRedriveCount == 0)
        #expect(abs(panelTop(f) - 345) < 0.5, "with 'Follow the PDF' off the panel stays where it was")
        _ = f.pdfWindow
        _ = f.panelWindow
    }
}
