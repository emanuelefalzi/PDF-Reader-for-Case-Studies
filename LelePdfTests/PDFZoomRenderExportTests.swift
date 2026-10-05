import Foundation
import AppKit
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// Exports a PNG of a marked page at two zoom levels, for the visual check the
/// brief asks for ("Export a PNG of a marked page at two zoom levels... and
/// read it back to confirm the marks still sit on the right words"). Same
/// pattern as `MapRenderExportTests.swift` (real off-screen rendering, PNGs
/// only in a local cache, never in the repository).
// `.serialized`: creates real `NSWindow`s, same reason as the other suites
// with real `PDFView`/`NSHostingView` instances.
extension HeavyTestSuites {
@MainActor
@Suite("PDF zoom · PNG export for visual inspection", .serialized)
struct PDFZoomRenderExportTests {
    @Test("page with an 'FDA' mark exported at 100% and 220% zoom")
    func exportMarkedPageAtTwoZoomLevels() throws {
        let text = "Il documento cita la FDA come autorità competente in materia."
        let sourceURL = try StoreFixtures.makeTextPDF(text: text, fileName: "zoom-export-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "zoom-export-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
        guard model.pdfDocument.page(at: 0) != nil else {
            Issue.record("document has no page 0")
            return
        }

        let markStart = text.distance(from: text.startIndex, to: text.range(of: "FDA")!.lowerBound)
        let textBlock = TextBlock(
            id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, cleanText: text, textHash: "h1", words: 10,
            spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
            lineRectsByPage: [:]
        )
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Blocco",
            marks: [Mark(id: "m1", termId: "t1", type: .underline, text: "FDA", source: .claude, page: 0, range: MarkRange(start: markStart, length: 3))]
        )
        model.analysisController.updateContext(
            fingerprint: "fp-zoom-export", documentTitle: "T", blocks: [textBlock],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )

        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        try render(model: model, scaleFactor: 1.0, to: outputRoot.appendingPathComponent("f4z-zoom-100.png"))
        try render(model: model, scaleFactor: 2.2, to: outputRoot.appendingPathComponent("f4z-zoom-220.png"))
    }

    /// The same real view as the app (`PDFKitView.makeNSView`): `PDFView` +
    /// `MarksOverlayView` as a subview, with `PDFReaderCoordinator` attached so
    /// that `scaleFactor = ...` follows exactly the same path as
    /// `PDFReaderCoordinator+WheelZoom.applyAnchoredZoom` (including overlay
    /// invalidation), not a manual reconstruction of the drawing.
    private func render(model: DocumentModel, scaleFactor: CGFloat, to url: URL) throws {
        guard let page = model.pdfDocument.page(at: 0) else { return }
        let pageBounds = page.bounds(for: .mediaBox)
        let viewportSize = CGSize(width: max(320, pageBounds.width * scaleFactor + 40), height: max(240, pageBounds.height * scaleFactor + 40))

        let pdfView = PDFView(frame: CGRect(origin: .zero, size: viewportSize))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .white
        pdfView.autoScales = false
        pdfView.scaleFactor = scaleFactor

        let window = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = pdfView
        window.layoutIfNeeded()

        let coordinator = PDFReaderCoordinator()
        coordinator.attach(to: pdfView, model: model)
        let bridge = PDFReaderBridge(pdfView: pdfView)
        model.readerBridge = bridge

        let overlay = MarksOverlayView(model: model, pdfView: pdfView)
        overlay.frame = pdfView.bounds
        pdfView.addSubview(overlay)
        bridge.marksOverlay = overlay
        model.visiblePageRange = 0 ... 0
        overlay.invalidate()

        pdfView.layoutSubtreeIfNeeded()
        pdfView.displayIfNeeded()

        // [TECHNICAL CHOICE] `PDFView.cacheDisplay(in:to:)` (used by
        // `MapRenderExportTests.render`, with an `NSHostingView`) exports a
        // completely white page for a `PDFView`: its real content is composed
        // via `CALayer` and does not go through `-drawRect:`, which is all
        // `cacheDisplay` captures; verified in this session (white PNG). So we
        // compose by hand, in our own bitmap context: `PDFPage.draw(with:to:)`
        // (the PDFKit API that draws the page's real content into a CGContext,
        // independent of `CALayer`/window) for the background, then the REAL
        // `overlay.draw(_:)` (the same mark drawing as the app, not redrawn by
        // hand) in the SAME context. The page's destination rectangle is the
        // one `pdfView.convert(_:from:)` gives, the SAME conversion the overlay
        // uses for its marks, not an independent computation of PDFKit's layout
        // (margins/centering): the two stay aligned by construction, whatever
        // `PDFView`'s real internal layout is.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(viewportSize.width), pixelsHigh: Int(viewportSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let nsContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = viewportSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        let cg = nsContext.cgContext

        func drawPageAndMarks() {
            cg.setFillColor(NSColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: viewportSize))
            let pageRectInView = pdfView.convert(pageBounds, from: page)
            if pageRectInView.width > 0, pageRectInView.height > 0 {
                cg.saveGState()
                cg.translateBy(x: pageRectInView.minX, y: pageRectInView.minY)
                cg.scaleBy(x: pageRectInView.width / pageBounds.width, y: pageRectInView.height / pageBounds.height)
                cg.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
                page.draw(with: .mediaBox, to: cg)
                cg.restoreGState()
            }
            overlay.draw(overlay.bounds)
        }

        // Marks appear with a fade-in (SPEC §5.5, `MarksOverlayView.fadeOpacity`):
        // the FIRST `draw(_:)` for an id never seen before starts the fade from
        // 0 (invisible). Without this "dry" pass (inside a valid graphics
        // context, otherwise `draw(_:)` returns immediately and never even
        // registers the id) plus a wait beyond `fadeDuration` (0.32s), the
        // exported PNG would show the page WITHOUT any mark, not because of a
        // geometry error but only because the fade has not settled yet
        // (observed in this session: first attempt, a page with no marks even
        // though `hitItems` had the right rectangle).
        drawPageAndMarks()
        Thread.sleep(forTimeInterval: 0.35)
        drawPageAndMarks()

        nsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
}
}
