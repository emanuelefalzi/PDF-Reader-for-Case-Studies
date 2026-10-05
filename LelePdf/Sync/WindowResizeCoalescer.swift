import AppKit

/// Signals the start/end of a "live" window resize (dragging the edge,
/// entering Full Screen, exiting Full Screen). Added for a bug the user
/// reported: "when I go full screen it takes 3 seconds and also shows a
/// hint of a loading wheel".
///
/// **Cause found** (by reading the code, no profiler available at the
/// time): `PDFView.autoScales = true` fires `.PDFViewScaleChanged` on
/// every intermediate frame of the Full Screen animation (the scale keeps
/// adapting to the growing width), and
/// `PDFReaderCoordinator.handleScaleChanged` calls
/// `ScrollSyncCoordinator.rebuildAlignment()` on EVERY notification,
/// rebuilding `AlignmentBuilder.build` (a pass over EVERY row of the
/// document, titles/blocks/Exhibits, not just the visible ones) dozens of
/// times during a single animation instead of once at the end of the
/// transition. Same principle for `RewriteScrollHost`: the width constraint
/// of the right panel's SwiftUI content follows the window on every frame,
/// redoing the layout of ALL the cards (not lazy, SPEC §5.6; the `Rewrite/`
/// module is deliberately left unrestructured) at every step of the
/// animation.
///
/// This type touches neither of the two heavy pipelines: it only says "a
/// transition is in progress" (`isTransitioning`) and notifies its
/// start/end (`.lelePdfResizeTransitionBegan`/`Ended`), so every observer
/// can defer its own heavy work to a single pass at the end; see
/// `ScrollSyncCoordinator.rebuildAlignment()` and `RewriteScrollHost.swift`.
extension Notification.Name {
    static let lelePdfResizeTransitionBegan = Notification.Name("LelePdfResizeTransitionBegan")
    static let lelePdfResizeTransitionEnded = Notification.Name("LelePdfResizeTransitionEnded")
}

@MainActor
final class WindowResizeCoalescer {
    private weak var window: NSWindow?
    private var tokens: [NSObjectProtocol] = []
    private(set) var isTransitioning = false

    /// Observed once per window (SPEC §6.3 "one `DocumentModel` per
    /// window"): called by `MarksOverlayView.viewDidMoveToWindow`, the first
    /// view of the `PDFView` to already have a real window by the time the
    /// user can move the mouse; no need for an earlier hook, the window
    /// cannot resize before it appears.
    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        let center = NotificationCenter.default
        let beginNames: [Notification.Name] = [
            NSWindow.willStartLiveResizeNotification,
            NSWindow.willEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification,
        ]
        let endNames: [Notification.Name] = [
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        for name in beginNames {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.begin() }
            })
        }
        for name in endNames {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            })
        }
    }

    /// Not `private`: tests (no real animated `NSWindow` is available in an
    /// XCTest suite) simulate the transition by calling these two methods
    /// directly instead of waiting for system notifications; see
    /// `WindowResizeCoalescerTests.swift`.
    func begin() {
        guard !isTransitioning else { return }
        isTransitioning = true
        NotificationCenter.default.post(name: .lelePdfResizeTransitionBegan, object: self)
    }

    func end() {
        guard isTransitioning else { return }
        isTransitioning = false
        NotificationCenter.default.post(name: .lelePdfResizeTransitionEnded, object: self)
    }

    func detach() {
        let center = NotificationCenter.default
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
        window = nil
        isTransitioning = false
    }
}
