import Foundation
import AppKit
import CoreGraphics
import CoreText
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// User feedback behind this test: the vertical blue bar on the left was not
/// clearly tied to the paragraph being read on the right, and the user asked
/// for something better. Exports PNGs of a real page (`PDFView` +
/// `ParagraphFocusOverlay` + `MarksOverlayView`, the SAME views used in
/// production, not a hand-redrawn imitation; `RectangleMarksOverlay` is not
/// needed here because this scenario has no rectangle marks) at two zoom
/// levels and in two states (the block "in focus" at the reading position,
/// and the same block ACTUALLY under the mouse) so they can be judged by
/// eye: (1) the color is the document subject's color, not the fixed blue
/// accent used before (here the subject is `.rosso`, clearly distinct from
/// blue, precisely so an old screenshot cannot be mistaken for a new one);
/// (2) the band behind the lines and the marker in the margin stay legible
/// over the text; (3) the "under the mouse" state (arrow + more intense
/// band) is clearly distinguishable from the "reading position only" state.
/// Same scheme as `PDFZoomRenderExportTests.swift`.
extension HeavyTestSuites {
@MainActor
@Suite("Focused paragraph band/marker: PNG export for visual inspection", .serialized)
struct ParagraphFocusRenderExportTests {
    /// Test page with two "paragraphs" (two groups of lines, well separated
    /// vertically). Unlike `StoreFixtures.makeTextPDF` (a single line), several
    /// lines per block are needed here to see a real band/capsule rather than
    /// a single dot.
    private func makeTwoParagraphPDF() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("due-paragrafi-\(UUID().uuidString).pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 520)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.beginPDFPage(nil)
        let font = NSFont.systemFont(ofSize: 13)
        func drawLine(_ text: String, y: CGFloat) {
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(line, ctx)
        }
        // Block "a" (topmost lines on the page; SPEC: top = start of the document).
        drawLine("Primo paragrafo del documento di prova, riga uno.", y: 460)
        drawLine("Primo paragrafo del documento di prova, riga due.", y: 440)
        drawLine("Primo paragrafo del documento di prova, riga tre.", y: 420)
        // Block "b", lower down.
        drawLine("Secondo paragrafo, quello che si legge dopo, riga uno.", y: 340)
        drawLine("Secondo paragrafo, quello che si legge dopo, riga due.", y: 320)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private func lineRect(y: CGFloat, width: CGFloat = 320, height: CGFloat = 16) -> PageRect {
        PageRect(x: 40, y: y - 4, width: width, height: height)
    }

    private func makeModel() throws -> (model: DocumentModel, pageURL: URL) {
        let sourceURL = try makeTwoParagraphPDF()
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "paragraph-focus-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let blockA = TextBlock(
            id: "a", sectionPath: [], pageStart: 0, pageEnd: 0,
            cleanText: "Primo paragrafo del documento di prova.", textHash: "ha", words: 8,
            spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: 40, charMap: Array(0 ..< 40))],
            lineRectsByPage: [0: [lineRect(y: 460), lineRect(y: 440), lineRect(y: 420)]]
        )
        let blockB = TextBlock(
            id: "b", sectionPath: [], pageStart: 0, pageEnd: 0,
            cleanText: "Secondo paragrafo, quello che si legge dopo.", textHash: "hb", words: 8,
            spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: 44, charMap: Array(0 ..< 44))],
            lineRectsByPage: [0: [lineRect(y: 340), lineRect(y: 320)]]
        )

        var analysis = AnalysisRecord()
        analysis.blocks["a"] = BlockAnalysis(status: .analyzed, title: "Blocco a")
        analysis.blocks["b"] = BlockAnalysis(status: .analyzed, title: "Blocco b")
        model.analysisController.updateContext(
            fingerprint: "fp-paragraph-focus", documentTitle: "T", blocks: [blockA, blockB],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )
        // `MarksOverlayDrawing.drawMarginBars`/`ParagraphFocusOverlay.draw`
        // read `model.structure?.blocks` (set in production by
        // `PipelineRunner` after the real text extraction), NOT
        // `analysisController.context` like `cardData(for:)`/the marks: a
        // different source, discovered here. Without this assignment the two
        // PNGs came out identical and completely blank, because
        // `model.structure` stayed `nil` and both views returned early from
        // the `guard`.
        model.structure = DocumentStructure(
            fingerprint: "fp-paragraph-focus", pageCount: 1, headings: [], tocCandidates: [],
            exhibits: [], blocks: [blockA, blockB], textlessPages: false, removedHeaderFooterLines: [:],
            paragraphs: []
        )
        // Subject color clearly distinct from the previous fixed blue accent
        // (the old bar was always blue, regardless of subject), so an old
        // screenshot cannot be mistaken for a new one.
        model.setColorTheme(.rosso)
        return (model, sourceURL)
    }

    @Test("block 'a' at the reading position (no hover): calm capsule and band, no arrow")
    func exportFocusedAtReadingPosition() throws {
        let (model, _) = try makeModel()
        model.currentPageIndex = 0 // reading position → block "a" (first one containing page 0)
        #expect(model.hoveredBlockId == nil)
        #expect(model.currentFocusedBlockId == "a")
        try render(model: model, scaleFactor: 1.0, to: outputURL("f5b2-focus-reading-position-100.png"))
        try render(model: model, scaleFactor: 2.0, to: outputURL("f5b2-focus-reading-position-200.png"))
    }

    @Test("block 'b' ACTUALLY under the mouse: more intense capsule/band, plus the arrow in the margin")
    func exportHoveredBlock() throws {
        let (model, _) = try makeModel()
        model.currentPageIndex = 0
        model.setHoveredBlock("b")
        #expect(model.currentFocusedBlockId == "b")
        try render(model: model, scaleFactor: 1.0, to: outputURL("f5b2-focus-hovered-100.png"))
        try render(model: model, scaleFactor: 2.0, to: outputURL("f5b2-focus-hovered-200.png"))
    }

    private func outputURL(_ name: String) throws -> URL {
        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        return outputRoot.appendingPathComponent(name)
    }

    /// Same real composition as `PDFKitView.makeNSView` (band → rectangle
    /// fills → marks/margin capsules), same offscreen capture scheme as
    /// `PDFZoomRenderExportTests.render`. `PDFView.cacheDisplay` exports a
    /// blank page (the real content is composed via `CALayer` and never goes
    /// through `-drawRect:`), so the image is composed by hand in a dedicated
    /// bitmap context with `PDFPage.draw(with:to:)` plus each view's real
    /// `draw(_:)`, all in the same `CGContext`.
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

        let paragraphFocusOverlay = ParagraphFocusOverlay(model: model, pdfView: pdfView)
        paragraphFocusOverlay.frame = pdfView.bounds

        let overlay = MarksOverlayView(model: model, pdfView: pdfView)
        overlay.frame = pdfView.bounds
        pdfView.addSubview(overlay)
        bridge.marksOverlay = overlay
        model.visiblePageRange = 0 ... 0
        overlay.invalidate()
        paragraphFocusOverlay.invalidate()

        pdfView.layoutSubtreeIfNeeded()
        pdfView.displayIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(viewportSize.width), pixelsHigh: Int(viewportSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let nsContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = viewportSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        let cg = nsContext.cgContext

        func drawEverything() {
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
            // Production order (`PDFKitView.makeNSView`): band (at the
            // bottom, multiply) → marks/margin capsules (on top, normal
            // alpha).
            paragraphFocusOverlay.draw(paragraphFocusOverlay.bounds)
            overlay.draw(overlay.bounds)
        }

        // As in `PDFZoomRenderExportTests`: marks appear with a fade-in, so
        // do one "dry" pass plus a wait longer than `fadeDuration` (0.32 s)
        // before the real draw that ends up in the PNG; otherwise the export
        // captures the page mid-fade. (There are no Claude marks here, and
        // the margin capsule depends on `blockState == .analyzed` rather than
        // on the fade, so the double pass is harmless and keeps the shared
        // scheme.)
        drawEverything()
        Thread.sleep(forTimeInterval: 0.35)
        drawEverything()

        nsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
}
}
