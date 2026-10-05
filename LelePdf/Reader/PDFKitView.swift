import SwiftUI
@preconcurrency import PDFKit

/// `PDFView` wrapped for SwiftUI (SPEC §6.2 "Reader"). Single-page
/// continuous mode, with initial auto-scaling (SPEC §5.1, §9: the first
/// page must appear immediately, with no heavy work at open).
struct PDFKitView: NSViewRepresentable {
    let model: DocumentModel

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.backgroundColor = NSColor(DSColor.windowBackground)

        // Restore the last page read (SPEC §5.2) before attaching the
        // coordinator, so as not to trigger a visible jump.
        if model.currentPageIndex > 0, let page = model.pdfDocument.page(at: model.currentPageIndex) {
            pdfView.go(to: page)
        }

        context.coordinator.attach(to: pdfView, model: model)
        let bridge = PDFReaderBridge(pdfView: pdfView)
        model.readerBridge = bridge

        // Linked scrolling (SPEC §5.8, M6): from here on the coordinator
        // observes this NSScrollView, see `Sync/ScrollSyncCoordinator.swift`.
        if let scrollView = bridge.enclosingScrollView {
            model.syncCoordinator.attachPDF(scrollView: scrollView, model: model)
            // Forced overlay scroller style rather than the one macOS picks
            // on its own: with a mouse attached and "Show scroll bars:
            // automatic" (System Settings) macOS would choose `.legacy`
            // (always visible), but the user wants scroll bars only when
            // hovering or scrolling. `.overlay` is already AppKit's native
            // behavior of appearing on scroll or when the pointer nears the
            // edge, so no hand-written mouse-tracking code is needed.
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }

        // Marks overlay (SPEC §5.4, M5b deliverable 1): a single NSView on
        // top of the PDFView itself, see `MarksOverlayView.swift` for the
        // technical choice (not `pageOverlayViewProvider`).
        let overlay = MarksOverlayView(model: model, pdfView: pdfView)
        overlay.frame = pdfView.bounds

        // Band for the paragraph "in focus" (the user found it unclear that
        // the margin bar is what highlights the paragraph being read): the
        // lowest of the multiply-blended views, a "background band" under
        // both the marks' fill and the text; see
        // `ParagraphFocusOverlay.swift`.
        let paragraphFocusOverlay = ParagraphFocusOverlay(model: model, pdfView: pdfView)
        paragraphFocusOverlay.frame = pdfView.bounds
        pdfView.addSubview(paragraphFocusOverlay)
        overlay.paragraphFocusOverlay = paragraphFocusOverlay

        // Fill of the "concept" mark (the user reported that the solid
        // underline covered the text underneath): a dedicated view BELOW
        // `overlay` (added first, hence lower in the stacking order) with a
        // multiply `compositingFilter` against the actual PDF; see
        // `RectangleMarksOverlay.swift`.
        let rectangleOverlay = RectangleMarksOverlay(model: model, pdfView: pdfView)
        rectangleOverlay.frame = pdfView.bounds
        rectangleOverlay.host = overlay
        pdfView.addSubview(rectangleOverlay)
        overlay.rectangleOverlay = rectangleOverlay

        pdfView.addSubview(overlay)
        bridge.marksOverlay = overlay

        // Free annotations overlay (SPEC §5.13, M7b): above the marks, same
        // `PDFView`; see `Annotations/AnnotationOverlayView.swift` for when
        // it captures mouse events.
        let annotationOverlay = AnnotationOverlayView(model: model, pdfView: pdfView)
        annotationOverlay.frame = pdfView.bounds
        pdfView.addSubview(annotationOverlay)
        bridge.annotationOverlay = annotationOverlay

        // Text pipeline (SPEC §5.2: starts after the first page is shown,
        // never blocking the open). The `Task` defers it until after
        // `makeNSView` returns synchronously, so the first page appears
        // immediately (SPEC §9).
        Task { @MainActor in
            PipelineRunner.run(model: model)
        }
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // Commands to the view go through `model.readerBridge`, not through
        // here: `updateNSView` must not reintroduce a loop with the state
        // the coordinator writes into the model.
    }

    func makeCoordinator() -> PDFReaderCoordinator {
        PDFReaderCoordinator()
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: PDFReaderCoordinator) {
        nsView.subviews.compactMap { $0 as? MarksOverlayView }.forEach { $0.stopObserving() }
        // Same explicit teardown for the free annotations, which had never
        // been wired up (a crash found while verifying, with test views and
        // windows torn down by hand); see
        // `AnnotationOverlayView.stopObserving()`.
        nsView.subviews.compactMap { $0 as? AnnotationOverlayView }.forEach { $0.stopObserving() }
        coordinator.detach()
    }
}
