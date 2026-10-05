import Foundation
import AppKit
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// Reported bug: "with ctrl+scroll wheel, zooming out took the app to the last
/// page. The direction is right." Reproduction with a REAL multi-page
/// `PDFView` (not just `PDFZoomGestureTests.swift`, which covers only the pure
/// scale/anchor math and never goes through
/// `NSClipView.constrainBoundsRect`): this suite calls
/// `PDFReaderCoordinator.applyWheelZoomStep` (the same method as the real
/// ⌃+wheel monitor, `Reader/PDFReaderCoordinator+WheelZoom.swift`) on a real
/// document, scrolled to a middle page, and checks that the visible page does
/// not change during a pure zoom (no scrolling intended by the user).
extension HeavyTestSuites {
@MainActor
@Suite("The page does not change during a pure ⌃+wheel zoom", .serialized)
struct PDFWheelZoomPageStabilityTests {
    private struct Fixture {
        let model: DocumentModel
        let pdfView: PDFView
        let coordinator: PDFReaderCoordinator
        let window: NSWindow
    }

    private func makeFixture(pageCount: Int = 20, viewportSize: CGSize = CGSize(width: 300, height: 200)) throws -> Fixture {
        let sourceURL = try StoreFixtures.makeMultiPageTextPDF(pageCount: pageCount, fileName: "zoom-page-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "zoom-page-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let pdfView = PDFView(frame: CGRect(origin: .zero, size: viewportSize))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1

        // NOT closed here: `Fixture.window` goes back to the caller and stays
        // alive for the whole test (`fixture.window.layoutIfNeeded()` is called
        // several times in the test body, after this function returns: closing
        // the window here would detach it from `pdfView` immediately and those
        // calls would become a silent no-op, defeating the only reason this
        // file exists, a real `PDFView` inside a real window). Each caller
        // closes it at the end of the test.
        let window = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pdfView
        window.layoutIfNeeded()

        let coordinator = PDFReaderCoordinator()
        coordinator.attach(to: pdfView, model: model)
        model.readerBridge = PDFReaderBridge(pdfView: pdfView)

        return Fixture(model: model, pdfView: pdfView, coordinator: coordinator, window: window)
    }

    private func currentPageIndex(_ fixture: Fixture) -> Int? {
        guard let page = fixture.pdfView.currentPage, let document = fixture.pdfView.document else { return nil }
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    @Test("zooming out with the cursor at various points of the viewport does not change the visible page, starting from a middle page")
    func zoomingOutFromMiddlePageKeepsThePageStable() throws {
        let fixture = try makeFixture()
        defer { closeTestWindow(fixture.window) }
        guard let middlePage = fixture.pdfView.document?.page(at: 10) else {
            Issue.record("test document has no page 10")
            return
        }
        fixture.pdfView.scaleFactor = 2.5
        fixture.pdfView.go(to: middlePage)
        fixture.window.layoutIfNeeded()

        let before = currentPageIndex(fixture)
        #expect(before == 10, "the test document must start on page 10 before the zoom")

        // Different anchor points (corners and center of the viewport): the
        // reported bug does not say where the cursor was, so we cover the whole
        // viewport instead of a single convenient point.
        let anchors: [CGPoint] = [
            CGPoint(x: 10, y: 10),
            CGPoint(x: 290, y: 10),
            CGPoint(x: 150, y: 100),
            CGPoint(x: 10, y: 190),
            CGPoint(x: 290, y: 190),
        ]

        for anchor in anchors {
            fixture.pdfView.scaleFactor = 2.5
            fixture.pdfView.go(to: middlePage)
            fixture.window.layoutIfNeeded()
            #expect(currentPageIndex(fixture) == 10, "setup: page 10 expected before anchor \(anchor)")

            // A single large "notch", like a non-precision mechanical wheel
            // after the `lineDeltaScale` factor. A burst is not needed to
            // reproduce the bug: a single scale jump is enough if the origin
            // computation is wrong.
            fixture.coordinator.applyWheelZoomStep(rawDelta: -600, atWindowPoint: anchor)
            fixture.window.layoutIfNeeded()

            let after = currentPageIndex(fixture)
            #expect(after == 10, "anchor \(anchor): the visible page changed from 10 to \(String(describing: after)) during a pure zoom out")
        }
    }

    @Test("a burst of zoom outs down below the fit-to-window scale does not change the visible page")
    func burstZoomOutBelowFitToWindowKeepsThePageStable() throws {
        let fixture = try makeFixture()
        defer { closeTestWindow(fixture.window) }
        guard let middlePage = fixture.pdfView.document?.page(at: 10) else {
            Issue.record("test document has no page 10")
            return
        }
        fixture.pdfView.scaleFactor = 3.0
        fixture.pdfView.go(to: middlePage)
        fixture.window.layoutIfNeeded()
        #expect(currentPageIndex(fixture) == 10)

        let fitScale = fixture.pdfView.scaleFactorForSizeToFit
        let anchor = CGPoint(x: 150, y: 100)

        // Successive steps, like a real burst (coalesced): each step is
        // checked, the page must never move.
        for _ in 0 ..< 12 {
            fixture.coordinator.applyWheelZoomStep(rawDelta: -400, atWindowPoint: anchor)
            fixture.window.layoutIfNeeded()
            #expect(currentPageIndex(fixture) == 10, "the page moved during the zoom-out burst, current scale \(fixture.pdfView.scaleFactor) (fit: \(fitScale))")
        }
        #expect(fixture.pdfView.scaleFactor < fitScale, "the test must go below the fit-to-window scale to reproduce the bug (content smaller than the viewport)")
    }
}
}
