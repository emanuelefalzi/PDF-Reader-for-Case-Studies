import Foundation
@preconcurrency import PDFKit

/// Observes `PDFView` notifications and updates the `DocumentModel`.
/// One-way only (view → model): commands in the other direction go through
/// `PDFReaderBridge`, so the two paths do not bounce off each other.
@MainActor
final class PDFReaderCoordinator: NSObject {
    /// Not `private`: also read by `PDFReaderCoordinator+WheelZoom.swift`
    /// (same type, separate file to keep files small) to apply ⌃+wheel/pinch
    /// zoom directly to the actual view.
    weak var pdfView: PDFView?
    weak var model: DocumentModel?
    private var observers: [NSObjectProtocol] = []
    /// Value of `pdfView.autoScales` before the transition in progress
    /// (reported bug: entering full screen took 3 seconds), `nil` outside a
    /// transition; see `handleResizeTransitionBegan`.
    private var autoScalesBeforeTransition: Bool?
    /// Local wheel/pinch monitor for ⌃+wheel = zoom (see
    /// `PDFReaderCoordinator+WheelZoom.swift`). Not `private`: managed by
    /// that file. Local (`NSEvent.addLocalMonitorForEvents`), never global:
    /// it only sees events already addressed to a window of THIS app, never
    /// those of other apps (so it cannot break the system accessibility zoom
    /// in other apps).
    var wheelZoomMonitor: Any?
    /// End of a ⌃+wheel burst: a mechanical wheel has no reliable `.ended`
    /// phase (only trackpads/Magic Mouse report it), so a safety timer
    /// re-armed on every event acts as a net in addition to the real phase
    /// when there is one; see `PDFReaderCoordinator+WheelZoom.swift`.
    var wheelZoomEndTimer: Timer?

    func attach(to pdfView: PDFView, model: DocumentModel) {
        detach()
        self.pdfView = pdfView
        self.model = model

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handlePageChanged() }
            },
            center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleScaleChanged() }
            },
            center.addObserver(forName: .PDFViewVisiblePagesChanged, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleVisiblePagesChanged() }
            },
            // `PDFView.autoScales = true` recomputes the fit scale on EVERY
            // frame of an animated resize (full screen, dragging the edge),
            // and each one also posts `.PDFViewScaleChanged` above, which in
            // turn used to run `rebuildAlignment()` over the whole document
            // (see `ScrollSyncCoordinator.rebuildAlignment`). During the
            // transition the scale stays at the last stable value;
            // `autoScales` returns to its previous state (and so refits)
            // with a single real pass at the end.
            center.addObserver(forName: .lelePdfResizeTransitionBegan, object: model.windowResizeCoalescer, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleResizeTransitionBegan() }
            },
            center.addObserver(forName: .lelePdfResizeTransitionEnded, object: model.windowResizeCoalescer, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleResizeTransitionEnded() }
            },
        ]

        // Initial state, so as not to wait for the first notification.
        handlePageChanged()
        handleScaleChanged()
        handleVisiblePagesChanged()

        // ⌃+wheel/pinch = zoom.
        installWheelZoomMonitor()
    }

    private func handleResizeTransitionBegan() {
        guard let pdfView, autoScalesBeforeTransition == nil else { return }
        autoScalesBeforeTransition = pdfView.autoScales
        pdfView.autoScales = false
    }

    private func handleResizeTransitionEnded() {
        guard let pdfView, let previousAutoScales = autoScalesBeforeTransition else { return }
        autoScalesBeforeTransition = nil
        // Reassigning `true` (if it was before) recomputes the fit scale
        // just once, now that the animation is over, the same principle as
        // `RewriteHostingCoordinator.unfreezeWidth()`.
        pdfView.autoScales = previousAutoScales
    }

    func detach() {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        removeWheelZoomMonitor()
    }

    deinit {
        // `detach()` cannot be called from a MainActor-isolated deinit
        // without an await; observers registered with a specific `object:`
        // expire together with the PDFView anyway, but they are removed as
        // soon as possible from `attach(to:model:)` if it is called again.
    }

    private func handlePageChanged() {
        PerfProbe.hit("pdfkit.pageChanged")
        guard let pdfView, let document = pdfView.document,
              let currentPage = pdfView.currentPage else { return }
        let index = document.index(for: currentPage)
        guard index != NSNotFound else { return }
        model?.currentPageIndex = index
        model?.noteReaderPageChanged(index)
    }

    private func handleScaleChanged() {
        PerfProbe.hit("pdfkit.scaleChanged")
        guard let pdfView else { return }
        model?.zoomPercent = Int((pdfView.scaleFactor * 100).rounded())
        model?.readerBridge?.invalidateOverlay()
        // SPEC §5.8: the PDF side's page-to-document coordinates depend on
        // the scale, so they must be recomputed on every zoom change (even
        // an indirect one, from a window resize with `autoScales`).
        model?.syncCoordinator.rebuildAlignment()
    }

    private func handleVisiblePagesChanged() {
        PerfProbe.hit("pdfkit.visiblePagesChanged")
        guard let pdfView, let document = pdfView.document else { return }
        let pages = pdfView.visiblePages.compactMap { document.index(for: $0) == NSNotFound ? nil : document.index(for: $0) }
        guard let minPage = pages.min(), let maxPage = pages.max() else { return }
        model?.visiblePageRange = minPage...maxPage
        model?.readerBridge?.invalidateOverlay()
    }
}
