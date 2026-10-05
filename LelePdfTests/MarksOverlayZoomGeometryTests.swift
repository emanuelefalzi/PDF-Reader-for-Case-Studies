import Foundation
import AppKit
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// Requirement: the marks overlay "must stay aligned at any zoom level (they
/// are drawn in page coordinates: verify, do not assume)". Checked with a REAL
/// `PDFView`/`MarksOverlayView` (not just the pure math of `PDFZoomGesture`,
/// covered by `PDFZoomGestureTests.swift`): marks live in PAGE space
/// (`AnalysisControllerMarks.lineRects`, via `PDFSelection.bounds(for:)`) and
/// `MarksOverlayView.hitItems(forPage:)` converts them to VIEW space with
/// `PDFView.convert(_:from:)`. This suite changes `scaleFactor` the way a burst
/// of ⌃+wheel would (`PDFReaderCoordinator+WheelZoom.swift`) and checks that
/// the cache never stays on a stale conversion.
extension HeavyTestSuites {
@MainActor
@Suite("Mark geometry at multiple zoom levels", .serialized)
struct MarksOverlayZoomGeometryTests {
    private struct Fixture {
        let model: DocumentModel
        let pdfView: PDFView
        let overlay: MarksOverlayView
        let coordinator: PDFReaderCoordinator
        let page: PDFPage
    }

    /// A page with a real sentence, a block covering all of it, and a mark
    /// (`.underline`, drawn entirely by `MarksOverlayView` itself, SPEC
    /// §5.4/`MarksOverlayDrawing.swift`, no need for `RectangleMarksOverlay`)
    /// on the word "FDA".
    private func makeFixture(viewportSize: CGSize = CGSize(width: 240, height: 240)) throws -> Fixture {
        let text = "Il documento cita la FDA come autorità competente."
        let sourceURL = try StoreFixtures.makeTextPDF(text: text, fileName: "zoom-geom-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "zoom-geom-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
        guard let page = model.pdfDocument.page(at: 0) else { throw CocoaError(.fileReadUnknown) }

        let markStart = text.distance(from: text.startIndex, to: text.range(of: "FDA")!.lowerBound)
        let textBlock = TextBlock(
            id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, cleanText: text, textHash: "h1", words: 8,
            spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
            lineRectsByPage: [:]
        )
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Blocco",
            marks: [Mark(id: "m1", termId: "t1", type: .underline, text: "FDA", source: .claude, page: 0, range: MarkRange(start: markStart, length: 3))]
        )
        model.analysisController.updateContext(
            fingerprint: "fp-zoom-geom", documentTitle: "T", blocks: [textBlock],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )

        let pdfView = PDFView(frame: CGRect(origin: .zero, size: viewportSize))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1

        let window = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = pdfView
        window.layoutIfNeeded()

        let coordinator = PDFReaderCoordinator()
        coordinator.attach(to: pdfView, model: model)
        model.readerBridge = PDFReaderBridge(pdfView: pdfView)

        let overlay = MarksOverlayView(model: model, pdfView: pdfView)
        overlay.frame = pdfView.bounds
        pdfView.addSubview(overlay)
        model.readerBridge?.marksOverlay = overlay
        model.visiblePageRange = 0 ... 0

        return Fixture(model: model, pdfView: pdfView, overlay: overlay, coordinator: coordinator, page: page)
    }

    /// Rectangle (page space) of the "FDA" mark, recomputed from scratch on
    /// every call (same source as `AnalysisControllerMarks`, not the overlay's
    /// cache): a reference truth independent of `MarksOverlayView.hitItems`.
    private func referencePageRect(fixture: Fixture) -> CGRect {
        let items = fixture.model.analysisController.markItems(forPage: 0, document: fixture.model.pdfDocument)
        let item = items.first { $0.markId == "m1" }
        return item?.lineRects.first ?? .zero
    }

    @Test("at several zoom levels, the mark's rectangle in view space matches a fresh PDFKit conversion (no stale cache)")
    func markRectMatchesFreshConversionAtEachZoomLevel() throws {
        let fixture = try makeFixture()
        let referencePageRect = referencePageRect(fixture: fixture)
        #expect(referencePageRect != .zero, "the 'FDA' mark must produce a real rectangle")

        // Zoom levels traversed as in a burst of ⌃+wheel events, not just a
        // single jump.
        for scale: CGFloat in [1.0, 0.5, 1.75, 3.0, 1.0] {
            fixture.pdfView.scaleFactor = scale // same call as `PDFReaderCoordinator+WheelZoom.applyAnchoredZoom`.

            let expectedViewRect = fixture.pdfView.convert(referencePageRect, from: fixture.page)
            let entries = fixture.overlay.hitItems(forPage: 0)
            let actual = entries.first { $0.item.markId == "m1" }?.rects.first

            #expect(actual != nil, "scale \(scale): the mark must have a rectangle in view space")
            if let actual {
                #expect(abs(actual.minX - expectedViewRect.minX) < 0.5, "scale \(scale): x out of place (\(actual) vs expected \(expectedViewRect))")
                #expect(abs(actual.minY - expectedViewRect.minY) < 0.5, "scale \(scale): y out of place (\(actual) vs expected \(expectedViewRect))")
                #expect(abs(actual.width - expectedViewRect.width) < 0.5, "scale \(scale): width out of place")
                #expect(abs(actual.height - expectedViewRect.height) < 0.5, "scale \(scale): height out of place")
            }
        }
    }

    @Test("doubling the scale (roughly) doubles the size of the mark's rectangle")
    func markRectScalesProportionally() throws {
        let fixture = try makeFixture()

        fixture.pdfView.scaleFactor = 1
        let widthAt1 = fixture.overlay.hitItems(forPage: 0).first { $0.item.markId == "m1" }?.rects.first?.width
        let widthAt1Unwrapped = try #require(widthAt1)

        fixture.pdfView.scaleFactor = 2
        let widthAt2 = fixture.overlay.hitItems(forPage: 0).first { $0.item.markId == "m1" }?.rects.first?.width
        let widthAt2Unwrapped = try #require(widthAt2)

        #expect(abs(widthAt2Unwrapped - widthAt1Unwrapped * 2) < 0.5, "expected \(widthAt1Unwrapped * 2), got \(widthAt2Unwrapped)")
    }

    @Test("after a burst of zoom changes, hit testing the mark's center still finds the same word (no cumulative drift)")
    func hoverHitTestFindsMarkAfterZoomBurst() throws {
        let fixture = try makeFixture()

        for scale: CGFloat in [1.0, 1.4, 0.8, 2.2, 1.0] {
            fixture.pdfView.scaleFactor = scale
            let entries = fixture.overlay.hitItems(forPage: 0)
            guard let rect = entries.first(where: { $0.item.markId == "m1" })?.rects.first else {
                Issue.record("scale \(scale): no rectangle for the mark")
                continue
            }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            #expect(MarkGeometry.hitTest(center, rects: [rect]), "scale \(scale): the center of its own rectangle must always pass the hit test")
        }
    }
}
}
