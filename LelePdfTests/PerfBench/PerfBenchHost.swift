import AppKit
import SwiftUI
@preconcurrency import PDFKit
@testable import LelePdf

/// A real window with the REAL three-column layout (`ThreePaneLayout`:
/// sidebar with contents/thumbnails, `PDFView` with the three overlays, right
/// panel in `RewriteScrollHost`) mounted in an `NSHostingView`, as in the
/// app, so every measured interaction goes through the same notifications,
/// the same `@Observable`s, the same `NSTextView`s.
///
/// Off-screen by default: a window that was never shown gets no `CAContext`,
/// so `displayIfNeeded()` does not call `draw(_:)` on layer-backed views; the
/// drawing cost of the overlays is therefore forced with
/// `cacheDisplay(in:to:)` on a bitmap at the window's scale (the same
/// CoreGraphics rasterization AppKit would do into the layer's backing
/// store). With `LELEPDF_BENCH_ONSCREEN=1` the window is shown for real and
/// the real `displayIfNeeded()` + `CATransaction.flush()` are measured.
@MainActor
final class PerfBenchHost {
    let model: DocumentModel
    let window: NSWindow
    let hosting: NSHostingView<AnyView>
    let onScreen: Bool
    private(set) var pdfView: PDFView?
    private(set) var overlays: [NSView] = []
    private var bitmapCache: [ObjectIdentifier: NSBitmapImageRep] = [:]
    /// Memory guard (F6-ALL): checked by `PerfBenchScenarios.finishFrame`
    /// after every frame; `memoryGuardStep` is the label of the step in
    /// progress, for the error message.
    let memoryGuard = PerfBenchMemoryGuard()
    var memoryGuardStep = ""

    /// Memory diagnostics: bitmaps kept in cache for dirty views (count and
    /// MB); key = view identity, so a replaced view leaves its bitmap here
    /// until it is cleaned up.
    var bitmapCacheStats: (count: Int, megabytes: Double) {
        let bytes = bitmapCache.values.reduce(0) { $0 + $1.bytesPerRow * $1.pixelsHigh }
        return (bitmapCache.count, Double(bytes) / 1_048_576)
    }

    /// Memory diagnostics: `MarkedNSTextView` lives in the right panel.
    func textViewCount() -> Int {
        var targets: [NSView] = []
        if let container = panelScrollView?.documentView { collectTextViews(container, into: &targets) }
        return targets.count
    }

    init(model: DocumentModel, size: CGSize, onScreen: Bool) {
        self.model = model
        self.onScreen = onScreen
        let root = AnyView(ThreePaneLayout().environment(model).frame(width: size.width, height: size.height))
        hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "LelePdf · F5 benchmark harness"
        window.contentView = hosting
        if onScreen { window.orderFrontRegardless() }
    }

    /// One layout pass + wait until SwiftUI/AppKit have mounted the AppKit
    /// views (`readerBridge`, `rewriteScrollView`) and the row rectangles have
    /// reached `ScrollSyncCoordinator` (segments). Duration of the FIRST full
    /// layout pass (right panel with all the cards included): it is already a
    /// measurement, "opening an analyzed document"; see the report.
    private(set) var firstLayoutMs: Double = 0
    private(set) var secondLayoutMs: Double = 0

    func settle(maxSeconds: Double = 8) async throws {
        var start = CFAbsoluteTimeGetCurrent()
        hosting.layoutSubtreeIfNeeded()
        firstLayoutMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        start = CFAbsoluteTimeGetCurrent()
        hosting.layoutSubtreeIfNeeded()
        secondLayoutMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let deadline = Date().addingTimeInterval(maxSeconds)
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            if model.readerBridge?.enclosingScrollView != nil, model.rewriteScrollView != nil, !model.syncCoordinator.segments.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        pdfView = model.readerBridge?.pdfView
        overlays = pdfView?.subviews.filter { $0 is MarksOverlayView || $0 is RectangleMarksOverlay || $0 is AnnotationOverlayView } ?? []
        // Thumbnails and initial `.task`s: let them finish before measuring.
        try await pump(seconds: 0.6)
    }

    /// Yields the main thread for `seconds`, letting `.task`/notifications/
    /// timers run as in the app.
    func pump(seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    var pdfScrollView: NSScrollView? { model.readerBridge?.enclosingScrollView }
    var panelScrollView: NSScrollView? { model.rewriteScrollView }
    var marksOverlay: MarksOverlayView? { overlays.compactMap { $0 as? MarksOverlayView }.first }

    // MARK: - "Frame": layout + drawing of whatever is dirty

    struct FrameCost {
        var layoutMs: Double = 0
        var drawMs: Double = 0
        var drawnViews: Int = 0
        var total: Double { layoutMs + drawMs }
    }

    /// Closes the frame after an interaction: layout of the whole tree, then
    /// drawing of the dirty views. Returns the two costs separately.
    @discardableResult
    func frame() -> FrameCost {
        var cost = FrameCost()
        let layoutStart = CFAbsoluteTimeGetCurrent()
        hosting.layoutSubtreeIfNeeded()
        cost.layoutMs = (CFAbsoluteTimeGetCurrent() - layoutStart) * 1000

        let drawStart = CFAbsoluteTimeGetCurrent()
        if onScreen {
            window.displayIfNeeded()
            CATransaction.flush()
            cost.drawnViews = -1
        } else {
            cost.drawnViews = drawDirtyViews()
        }
        cost.drawMs = (CFAbsoluteTimeGetCurrent() - drawStart) * 1000
        return cost
    }

    /// Off-screen: rasterizes every dirty view among the PDF overlays and the
    /// right panel's `MarkedNSTextView`s into the (reused) bitmap of its size
    /// at the window's scale, then marks it clean, as AppKit would when
    /// updating the layer's backing store.
    private func drawDirtyViews() -> Int {
        var drawn = 0
        var targets: [NSView] = overlays
        if let container = panelScrollView?.documentView { collectTextViews(container, into: &targets) }
        for view in targets where view.needsDisplay && !view.isHidden && view.bounds.width > 0 && view.bounds.height > 0 {
            let key = ObjectIdentifier(view)
            let rep: NSBitmapImageRep
            if let cached = bitmapCache[key], cached.pixelsWide == Int(view.bounds.width * window.backingScaleFactor),
               cached.pixelsHigh == Int(view.bounds.height * window.backingScaleFactor) {
                rep = cached
            } else {
                guard let fresh = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                bitmapCache[key] = fresh
                rep = fresh
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            view.needsDisplay = false
            drawn += 1
        }
        return drawn
    }

    private func collectTextViews(_ view: NSView, into result: inout [NSView]) {
        if view is MarkedNSTextView { result.append(view) }
        for subview in view.subviews { collectTextViews(subview, into: &result) }
    }

    /// Cost of a complete rasterization of the `PDFView` (PDFKit pages
    /// included) at the window's scale: informational, one-off.
    func rasterizePDFViewMs() -> Double {
        guard let pdfView, let rep = pdfView.bitmapImageRepForCachingDisplay(in: pdfView.bounds) else { return 0 }
        let start = CFAbsoluteTimeGetCurrent()
        pdfView.cacheDisplay(in: pdfView.bounds, to: rep)
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    func close() {
        if onScreen { window.orderOut(nil) }
        window.contentView = nil
    }
}
