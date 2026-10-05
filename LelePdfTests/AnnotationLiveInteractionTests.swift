import Testing
import Foundation
import AppKit
@preconcurrency import PDFKit
@testable import LelePdf

/// Reproduction of the user's live feedback: "highlights from the top menu
/// don't work" and "neither does writing on the doc" — unlike the rest of
/// the `Annotations/` suite (`ReviewM7bTests`, `AnnotationControllerTests`...),
/// which calls `AnnotationTextMarkupCreator`/`AnnotationController`
/// directly, here real `hitTest`/`mouseDown` calls go through the SAME view
/// hierarchy as `PDFKitView.makeNSView` (real PDFView + 3 overlays in the
/// same order).
///
/// A real `NSWindow` is needed ONLY by the test that must exercise
/// `NSWindow.sendEvent(_:)` (the `acceptsFirstMouse` fix): an
/// `AnnotationOverlayView` added as a subview of a `PDFView` inside a real
/// window installs an `NSTrackingArea` that AppKit may call back
/// asynchronously during its own display cycle — a real crash was found
/// (`EXC_BAD_ACCESS`/`EXC_BREAKPOINT` in `isFlipped`/`updateTrackingAreas`
/// on a view with no Swift referents left) when a window built this way was
/// torn down by hand between tests. All the other tests below use
/// `hitTest(_:)`/direct notifications, which do not need a view installed
/// in a real window, and therefore stay on a scene WITHOUT a window
/// (`Scene`); only `WindowedScene` (two tests, much more careful teardown)
/// builds a real one.
extension HeavyTestSuites {
@MainActor
@Suite("Annotations: live interaction (Annotate bar)", .serialized)
struct AnnotationLiveInteractionTests {
    // MARK: - Scene without a window (most tests)

    private struct Scene {
        let model: DocumentModel
        let pdfView: PDFView
        let annotationOverlay: AnnotationOverlayView
        let marksOverlay: MarksOverlayView
    }

    /// Same views as `PDFKitView.makeNSView` (SPEC §5.13), but NEVER added
    /// as subviews of `pdfView`, nor `pdfView` put in a window: `hitTest(_:)`
    /// takes a point already in VIEW space (no `convert(_:from: nil)` that
    /// depends on `self.window`), and all tests of this scene call it directly
    /// or go through real notifications (`NotificationCenter`) rather than
    /// `NSWindow.sendEvent`.
    private func makeScene(text: String = "Ciao mondo prova LelePdf annotazioni dal vivo") throws -> Scene {
        let sourceURL = try StoreFixtures.makeTextPDF(text: text, fileName: "live-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "live-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1

        let marksOverlay = MarksOverlayView(model: model, pdfView: pdfView)
        marksOverlay.frame = pdfView.bounds
        let annotationOverlay = AnnotationOverlayView(model: model, pdfView: pdfView)
        annotationOverlay.frame = pdfView.bounds

        return Scene(model: model, pdfView: pdfView, annotationOverlay: annotationOverlay, marksOverlay: marksOverlay)
    }

    // MARK: - Bug "highlights from the top menu don't work"

    @Test("with Highlight active the overlay captures the whole gesture, without depending on the private PDFPageView")
    func highlightToolCapturesTextMarkupGesture() throws {
        let scene = try makeScene()
        let controller = scene.model.annotationController
        controller.barVisible = true
        controller.selectTool(.highlight)

        let point = CGPoint(x: 60, y: 100)
        let hit = scene.annotationOverlay.hitTest(point)
        #expect(hit === scene.annotationOverlay, "the gesture must reach the overlay until mouse-up")

        // The marks layer (`MarksOverlayView`, below the annotations) stays
        // transparent: the annotations overlay is above it and owns the whole
        // gesture on the text.
        let marksHit = scene.marksOverlay.hitTest(point)
        #expect(marksHit == nil, "MarksOverlayView must not interfere with the gesture on the text")
    }

    @Test("a native PDFView selection, with the Highlight tool active, really reaches the controller through the .PDFViewSelectionChanged observer")
    func highlightToolReactsToRealPDFViewSelectionNotification() throws {
        // This keeps compatibility with a selection set by PDFKit through paths
        // other than our gesture (for example keyboard or accessibility). The
        // regression of the real drag is now covered separately by
        // `AnnotationTextMarkupRealEventTests`, which sends down/drag/up to the
        // `NSWindow` with no direct calls.
        let scene = try makeScene()
        let controller = scene.model.annotationController
        controller.barVisible = true
        controller.selectTool(.highlight)

        guard let page = scene.pdfView.document?.page(at: 0), let text = page.string, !text.isEmpty else {
            Issue.record("test page without text")
            return
        }
        let selection = try #require(page.selection(for: NSRange(location: 0, length: min(10, (text as NSString).length))))
        scene.pdfView.setCurrentSelection(selection, animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: scene.pdfView)

        #expect(!controller.annotations.isEmpty, "a non-empty selection with Highlight active must reach the annotation through the real observer (SPEC §5.13 \"drag over the text and it stays highlighted\")")
        #expect(controller.annotations.allSatisfy { $0.kind == .highlight })
    }

    // MARK: - Historical regression: the mark under the text stays
    // transparent when a markup tool is active. The top overlay now owns the
    // whole gesture anyway, but the guard remains necessary if the hierarchy
    // changes or the overlay is torn down.

    private func seedOverlappingMark(on scene: Scene, text: String) {
        let block = TextBlock(
            id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, cleanText: text, textHash: "b1", words: 8,
            spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
            lineRectsByPage: [:]
        )
        let mark = Mark(id: "m1", termId: "t1", type: .rectangle, text: "Ciao mondo", source: .claude, page: 0, range: MarkRange(start: 0, length: 10))
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [mark])
        scene.model.analysisController.updateContext(
            fingerprint: "fp-live", documentTitle: "T", blocks: [block], exhibits: [],
            analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )
    }

    @Test("support check: the seeded analysis mark really covers the test point")
    func seededMarkCoversTestPointSanityCheck() throws {
        let text = "Ciao mondo prova LelePdf annotazioni dal vivo"
        let scene = try makeScene(text: text)
        seedOverlappingMark(on: scene, text: text)

        let point = CGPoint(x: 30, y: 145) // above "Ciao mondo", baseline y=150
        #expect(scene.marksOverlay.hitTest(point) != nil, "the test reproduces nothing if the seeded mark does not cover the point")
    }

    @Test("real cause: with Highlight active, an existing analysis mark under the text must NOT intercept the click meant for the PDFView's native selection")
    func highlightToolMustIgnoreExistingMarksUnderTheClick() throws {
        let text = "Ciao mondo prova LelePdf annotazioni dal vivo"
        let scene = try makeScene(text: text)
        let controller = scene.model.annotationController
        controller.barVisible = true
        controller.selectTool(.highlight)
        seedOverlappingMark(on: scene, text: text)

        let point = CGPoint(x: 30, y: 145)
        #expect(scene.annotationOverlay.hitTest(point) === scene.annotationOverlay, "the top overlay owns the gesture on the text")
        #expect(
            scene.marksOverlay.hitTest(point) == nil,
            "MarksOverlayView must not steal the click from the PDFView when the Annotate bar is on Highlight/Underline/Strikethrough: otherwise highlighting text already marked by the analysis (practically always, since the marks sit on the important text) never starts the native selection"
        )
    }

    // MARK: - Scene with a real window (only where `NSWindow.sendEvent` is needed)

    private struct WindowedScene {
        let model: DocumentModel
        let window: NSWindow
        let annotationOverlay: AnnotationOverlayView
    }

    private func makeWindowedScene(text: String = "Ciao mondo prova LelePdf annotazioni dal vivo") throws -> WindowedScene {
        let sourceURL = try StoreFixtures.makeTextPDF(text: text, fileName: "live-win-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "live-win-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1

        let window = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pdfView
        window.layoutIfNeeded()
        // `makeKeyAndOrderFront` was removed while hunting the crash, on
        // suspicion — WRONG: the real cause was the tracking area never
        // explicitly removed (`AnnotationOverlayView.stopObserving()`, below),
        // not ordering the window on screen. Removing it SILENTLY broke this
        // test: a window never ordered on screen even once does not go through
        // the normal click routing of `NSWindow.sendEvent` — it stays "not key"
        // anyway, but `acceptsFirstMouse(for:)` alone is not enough if the window
        // has never been "ordered" (found with `firstResponder` staying the
        // window itself instead of the overlay, even though `acceptsFirstMouse`
        // already answered `true` and `hitTest` already resolved the overlay
        // correctly). Safe to put back now, since the explicit teardown below
        // prevents the crash regardless.
        window.makeKeyAndOrderFront(nil)

        let annotationOverlay = AnnotationOverlayView(model: model, pdfView: pdfView)
        annotationOverlay.frame = pdfView.bounds
        pdfView.addSubview(annotationOverlay)

        return WindowedScene(model: model, window: window, annotationOverlay: annotationOverlay)
    }

    /// Deterministic, careful teardown (crash found earlier:
    /// `EXC_BAD_ACCESS`/`EXC_BREAKPOINT` when AppKit calls
    /// `isFlipped`/`updateTrackingAreas()` on this view during its own display
    /// cycle, AFTER a test had already removed it from the hierarchy but
    /// without a thorough enough teardown): explicit teardown of the tracking
    /// area/observer BEFORE detaching the view (`stopObserving()`, not relying
    /// only on `viewWillMove(toWindow:)`/deallocation), then several run loop
    /// turns. `window.close()` was tried and DISCARDED: it blocks the test
    /// process indefinitely (no real window server in a test host) —
    /// `orderOut(nil)` + `contentView = nil` remain the only combination that
    /// does not hang.
    private func teardown(_ scene: WindowedScene) {
        scene.annotationOverlay.stopObserving()
        scene.annotationOverlay.removeFromSuperview()
        scene.window.contentView = nil
        scene.window.orderOut(nil)
        for _ in 0 ..< 10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
    }

    // MARK: - Bug "and neither does writing on the doc" (textbox)

    @Test("a click with the Text tool, sent as a real NSEvent to the window, opens the editor and creates the annotation")
    func textboxToolCreatesAnnotationFromRealWindowEvent() throws {
        let scene = try makeWindowedScene()
        defer { teardown(scene) }
        let controller = scene.model.annotationController
        controller.barVisible = true
        controller.selectTool(.textbox)

        let point = CGPoint(x: 60, y: 100)
        // Independent check of the routing (SPEC §5.13 "captures everything"
        // for an active drawing/text tool): the annotations overlay must be
        // responsible for the point, not the marks below it nor the bare
        // PDFView.
        let hit = scene.annotationOverlay.hitTest(point)
        #expect(hit === scene.annotationOverlay, "with the Text tool active the annotations overlay must capture the click")

        // User-reported bug: without `acceptsFirstMouse(for:)` — missing until
        // then — `NSWindow.sendEvent` did not call `mouseDown(with:)` on the
        // overlay at all when the window was not yet "key" (for example right
        // after closing the Highlight color dropdown). A second, TEST-only
        // condition proved necessary: the window must have been ordered on screen
        // at least once (`makeKeyAndOrderFront`, below in `makeWindowedScene`) for
        // `NSWindow.sendEvent` to consider it "its own" and really hit-test — a
        // window never shown does not meet this condition regardless of
        // `acceptsFirstMouse`. It is not a second cause of the user's bug (the
        // real document window is always shown by `DocumentGroup`): it only
        // concerns the fidelity of THIS test, which had in fact been silently
        // broken after `makeKeyAndOrderFront` was removed on suspicion while
        // hunting the crash (real cause of the crash: the tracking area never
        // explicitly removed, see `AnnotationOverlayView.stopObserving()`).
        scene.window.sendEvent(mouseEvent(.leftMouseDown, at: point, in: scene.window))

        let textView = try #require(scene.annotationOverlay.activeTextBoxView, "the click with the Text tool must open the textbox editor (SPEC §5.13 \"click on the page, type directly\")")
        #expect(scene.window.firstResponder === textView, "the editor must become the first responder so typing can start right away")

        textView.string = "Prova dal vivo"
        _ = scene.window.makeFirstResponder(nil) // resignFirstResponder → commit (AnnotationTextBoxTextView)

        let created = try #require(controller.annotations.first { $0.kind == .textbox })
        #expect(created.text == "Prova dal vivo")
    }

    // MARK: - Crash found earlier: repeated teardown

    /// `EXC_BAD_ACCESS`/`EXC_BREAKPOINT` during AppKit's display cycle
    /// (`updateTrackingAreas()`/`isFlipped` called on a view with no Swift
    /// referents left) when a test `NSWindow`/`PDFView`/`AnnotationOverlayView`
    /// was torn down without a thorough enough teardown. Creates, shows and
    /// tears down the scene WITH a window several times in a row, with the same
    /// `teardown(_:)` used by the test above (not a more permissive standard
    /// double): exactly the same sequence — create, interact, tear down
    /// immediately, next test — that made the original crash show up across the
    /// whole suite.
    @Test("creating and tearing down the scene WITH a window several times in a row does not crash the process")
    func repeatedWindowedSceneLifecycleDoesNotCrash() throws {
        // 3 repetitions, not 20: every `makeWindowedScene` creates a real
        // `DocumentModel` (real pipeline/Store, not a lightweight test double) —
        // a higher number in a tight loop on the same MainActor queues up too much
        // real asynchronous work (found earlier: a huge stall/slowdown of the test
        // process, not a crash) before even reaching the point this test really
        // wants to verify (the VIEW's life/death cycle).
        for iteration in 0 ..< 3 {
            let scene = try makeWindowedScene(text: "Ciclo di smontaggio \(iteration)")
            let controller = scene.model.annotationController
            controller.barVisible = true
            controller.selectTool(.textbox)
            _ = scene.annotationOverlay.hitTest(CGPoint(x: 60, y: 100))
            scene.window.sendEvent(mouseEvent(.leftMouseDown, at: CGPoint(x: 60, y: 100), in: scene.window))
            teardown(scene)
        }
        // If we get here without a crash (seen repeatedly before the fix), the
        // life/death cycle is healthy.
        #expect(Bool(true))
    }
}
}
