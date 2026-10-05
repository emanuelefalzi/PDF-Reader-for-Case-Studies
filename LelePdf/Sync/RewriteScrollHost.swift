import SwiftUI
import AppKit

/// SwiftUI coordinate space of the root of the panel content (SPEC §5.8):
/// `RewriteRowStack` measures its own top and width in it, from which
/// `RewritePanelGeometry` derives the rectangles of all the rows. It is not
/// the window, so the rectangles stay stable while scrolling (they change
/// only for a new layout), exactly like the PDF side's document space
/// (`DocumentSpace`). This replaces the earlier per-row
/// `RowFramesPreferenceKey` (a `GeometryReader` for EVERY row built), which
/// with a lazy stack would have no rectangles for off-window rows.
enum RewriteSyncCoordinateSpace {
    static let name = "lelePdfRewriteContent"
}

/// Flipped container that serves as the real `documentView` of the
/// `NSScrollView` (SPEC §5.8, `DocumentSpace`): this way the right panel is
/// already in the "scrolling downward" space common to both sides, without
/// having to match an assumption with how SwiftUI orients its own host. The
/// PDF side (PDFKit's, not ours) instead reads `isFlipped` at runtime
/// because there we cannot decide it ourselves. `NSHostingView.isFlipped`
/// cannot be overridden from outside the SwiftUI module (tried: build error
/// "overriding non-open property"), so the real `NSHostingView` stays
/// normal and is constrained to fill this container entirely. Through the 4
/// constraints, this container gets its width from the scroll's
/// `contentView` and its height from the `NSHostingView`, which reports it
/// to Auto Layout as its own ideal size for that width.
final class RewriteFlippedDocumentContainer: NSView {
    override var isFlipped: Bool { true }
}

/// Typed coordinator: avoids having to spell out the exact type (opaque,
/// because of `.coordinateSpace(name:)`) of the `rootView` in `updateNSView`.
///
/// Fix for the "full screen takes 3 seconds" bug: it also holds the two
/// width constraints of `container`: the normal flexible one
/// (`equalTo: scrollView.contentView.widthAnchor`, always active outside a
/// transition) and the "frozen" one (`equalToConstant`, swapped in for the
/// first during Full Screen/a live resize). Every change in the container's
/// width redoes the layout of the built cards (only those in the lazy
/// window, `RewritePanelGeometry`; before, ALL of them): with real
/// `NSHostingView`/`MarkedNSTextView` for each card, a non-trivial cost.
/// During the animation (dozens of intermediate frames) the width stays at
/// the last stable value; a single real pass happens at the end
/// (`unfreezeWidth`), when the animation is already over and there is no
/// intermediate frame left to show on screen.
@MainActor
final class RewriteHostingCoordinator {
    var hosting: NSHostingView<AnyView>?
    weak var container: NSView?
    weak var scrollView: NSScrollView?
    var flexibleWidthConstraint: NSLayoutConstraint?
    private var frozenWidthConstraint: NSLayoutConstraint?
    private var beginObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var viewportObservers: [NSObjectProtocol] = []

    /// The panel's visible part (top and height, `DocumentSpace` space)
    /// goes to `RewritePanelGeometry`, which decides which rows to build.
    /// Clip view bounds = scrolling; frame = size.
    func observeViewport(scrollView: NSScrollView, geometry: RewritePanelGeometry) {
        guard viewportObservers.isEmpty else { return }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            viewportObservers.append(center.addObserver(forName: name, object: clip, queue: .main) { [weak scrollView, weak geometry] _ in
                MainActor.assumeIsolated {
                    guard let scrollView, let geometry, let (top, height) = DocumentSpace.visibleTopDown(scrollView) else { return }
                    geometry.updateViewport(top: top, height: height)
                }
            })
        }
    }

    /// Called only once by `makeNSView` (guard below): observes THIS
    /// window's coalescer (`object:`, not `nil`, otherwise the transition of
    /// ANOTHER document window would also freeze/unfreeze this panel).
    func observeResizeTransitions(model: DocumentModel) {
        guard beginObserver == nil else { return }
        let center = NotificationCenter.default
        beginObserver = center.addObserver(forName: .lelePdfResizeTransitionBegan, object: model.windowResizeCoalescer, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.freezeWidth() }
        }
        endObserver = center.addObserver(forName: .lelePdfResizeTransitionEnded, object: model.windowResizeCoalescer, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unfreezeWidth() }
        }
    }

    private func freezeWidth() {
        guard let container, let flexibleWidthConstraint, frozenWidthConstraint == nil else { return }
        let currentWidth = container.bounds.width
        guard currentWidth > 0 else { return }
        flexibleWidthConstraint.isActive = false
        let frozen = container.widthAnchor.constraint(equalToConstant: currentWidth)
        frozen.isActive = true
        frozenWidthConstraint = frozen
    }

    private func unfreezeWidth() {
        guard let frozenWidthConstraint, let flexibleWidthConstraint else { return }
        frozenWidthConstraint.isActive = false
        self.frozenWidthConstraint = nil
        flexibleWidthConstraint.isActive = true
        // A single real pass, here, not one per frame of the animation that
        // just ended.
        scrollView?.layoutSubtreeIfNeeded()
    }

    /// Real bug found in the review pass ("notification observers never
    /// removed"): `observeResizeTransitions` registered `beginObserver`/
    /// `endObserver` but nobody ever removed them from
    /// `NotificationCenter.default`, unlike the same pattern in
    /// `WindowResizeCoalescer`/`ScrollSyncCoordinator`/`MarksOverlayView`,
    /// which all have a `detach()`. Every time SwiftUI recreated this
    /// `NSViewRepresentable` (new document window, or the same view removed
    /// and rebuilt) one more observer stayed behind, forever: not a crash
    /// (it captures `[weak self]`), but a real accumulation over the
    /// process's life. Called from `dismantleNSView` below, the same point
    /// where `PDFReaderCoordinator`/`MarkedTextView` remove their own.
    func detach() {
        let center = NotificationCenter.default
        if let beginObserver { center.removeObserver(beginObserver) }
        if let endObserver { center.removeObserver(endObserver) }
        viewportObservers.forEach { center.removeObserver($0) }
        viewportObservers.removeAll()
        beginObserver = nil
        endObserver = nil
    }
}

/// Right panel in a real `NSScrollView` instead of the plain SwiftUI
/// `ScrollView` used earlier (SPEC §5.8, §13: "If SwiftUI is not enough for
/// the right panel, NSScrollView with SwiftUI content"). The reason:
/// driving a SwiftUI `ScrollView` from outside, on every scroll frame of
/// the other side and without animation, has no API designed for that use
/// (`onScrollGeometryChange`/`ScrollPosition` are declarative) while
/// `NSScrollView` gives direct read/write of the position, the same
/// mechanism already in use for the PDF side. The content stays pure
/// SwiftUI (`RewritePanel`); only the scroll container changes.
struct RewriteScrollHost<Content: View>: NSViewRepresentable {
    let model: DocumentModel
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        // Same overlay style as the PDF (`Reader/PDFKitView.swift`):
        // decided "yes, consistent" when the author asked for it only for
        // the PDF, to avoid two different behaviors between the two
        // scrollable panels of the same window.
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        let hosting = NSHostingView(rootView: wrappedContent())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // This `NSHostingView` is not the window's root (that one belongs to
        // `DocumentWindowView`, managed by SwiftUI/`DocumentGroup`): without
        // disabling its participation in the window's MINIMUM/MAXIMUM size
        // computation, the two nested `NSHostingView`s confuse each other: a
        // crash reproduced and diagnosed (`NSHostingView.updateConstraints()`
        // → `updateWindowContentSizeExtremaIfNecessary()` → SIGTRAP inside
        // `_setFrameCommon:fromServer:`, system log during the first
        // automatic measurement). The options responsible for that
        // negotiation are `.minSize`/`.maxSize`/`.standardBounds` (window):
        // `[]` (all disabled, the first fix) avoided the crash but also
        // disabled `.intrinsicContentSize`, which has nothing to do with the
        // window: it is needed only so Auto Layout knows how tall `hosting`
        // must be (and therefore `container`, which the 4 constraints below
        // pin to its edges) based on the real SwiftUI content. Without it,
        // `container` had neither an intrinsic height nor an explicit
        // constraint: `NSScrollView` resolved `documentView.bounds.height`
        // to the visible rectangle's height alone, NEVER taller, so the panel
        // did not scroll at all (`DocumentSpace.maxScrollTopDown` always 0),
        // the real cause of the thousands-of-points deviation in the first
        // measurement run: every target was clamped to 0 or to the edge,
        // regardless of the segments. Only `.intrinsicContentSize` was
        // re-enabled: the window stays protected from the crash, and the
        // panel is scrollable again for the real height of the content.
        hosting.sizingOptions = [.intrinsicContentSize]
        let container = RewriteFlippedDocumentContainer()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        // `container` must already be in the window hierarchy (as the scroll's
        // `documentView`) *before* activating the width constraint toward
        // `scrollView.contentView`: otherwise the two views do not yet have a
        // common ancestor and `NSLayoutConstraint.activate` throws an
        // uncaught Objective-C exception → immediate crash (reproduced and
        // diagnosed from the real exception traceback, `asiBacktraces`, in
        // all 13 crashes of the first measurement run: `objc_exception_throw`
        // → `-[NSLayoutConstraint setActive:]` →
        // `RewriteScrollHost.makeNSView`). The 4 constraints internal to
        // `container` (which already share a common ancestor, `hosting`
        // being a subview of `container` since `addSubview` above) do not
        // have this problem, but are activated afterward to keep the same
        // order.
        scrollView.documentView = container
        let flexibleWidthConstraint = container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            flexibleWidthConstraint,
        ])
        context.coordinator.hosting = hosting
        context.coordinator.container = container
        context.coordinator.scrollView = scrollView
        context.coordinator.flexibleWidthConstraint = flexibleWidthConstraint
        // See `RewriteHostingCoordinator` above: freezes the width during
        // Full Screen/a live window resize.
        context.coordinator.observeResizeTransitions(model: model)

        scrollView.contentView.postsBoundsChangedNotifications = true
        model.rewriteScrollView = scrollView
        model.syncCoordinator.attachPanel(scrollView: scrollView, model: model)
        // Lazy panel; see `RewritePanelGeometry`.
        model.rewritePanelGeometry.model = model
        context.coordinator.observeViewport(scrollView: scrollView, geometry: model.rewritePanelGeometry)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // `PerfProbe`: every reassignment of `rootView` makes the panel's
        // whole SwiftUI tree re-evaluate, as measured by the test bench.
        PerfProbe.measure("swiftui.RewriteScrollHost.update") {
            context.coordinator.hosting?.rootView = wrappedContent()
        }
    }

    func makeCoordinator() -> RewriteHostingCoordinator { RewriteHostingCoordinator() }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: RewriteHostingCoordinator) {
        coordinator.detach()
    }

    private func wrappedContent() -> AnyView {
        AnyView(content().coordinateSpace(name: RewriteSyncCoordinateSpace.name))
    }
}
