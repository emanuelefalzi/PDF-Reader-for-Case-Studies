import Testing
import Foundation
import AppKit
@preconcurrency import PDFKit
@testable import LelePdf

/// Visual check of the "delete" (X) button: exports a PNG of a real note
/// with its button into `~/Library/Caches/LelePdf/verifica-screenshots/`
/// (same folder/convention as `CardItemOverlapTests`/
/// `HoverVisibilityAndAtariCardTests` etc.) and reads it back from disk to
/// confirm that the button's colored circle is really present in the saved
/// file — not just in the in-memory view. `pdfView.cacheDisplay(in:to:)`
/// includes the subviews (here `AnnotationOverlayView`), so the button
/// (drawn by `+DeleteButton.swift`) ends up in the PNG together with
/// everything else in `pdfView`. **Verified**: `cacheDisplay` (with or
/// without a real `NSWindow` behind it, both tried) does not draw PDFKit's
/// native content (page, note icon) — only the background and "regular"
/// AppKit subviews like this overlay; PDFKit probably composes the page
/// with its own Core Animation layer, which `cacheDisplay`/`draw(_:)` does
/// not intercept. This is not a limitation of the function under test (the
/// button): the scan below checks exactly that, with data read from the
/// saved file, not from the in-memory view. No real `NSWindow` here: an
/// offscreen capture does not need one for the button, which also avoids
/// any risk of reviving a crash seen earlier (a tracking area installed
/// only when AppKit runs the display cycle of a real window, never here).
extension HeavyTestSuites {
@MainActor
@Suite("Annotations: visual check of the delete button (PNG)", .serialized)
struct AnnotationDeleteButtonScreenshotTests {
    @Test("PNG of a selected note with the delete button: the button's colored circle is present in the saved file")
    func noteWithDeleteButtonScreenshotContainsAccentCircle() throws {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Pagina di prova per lo screenshot del bottone elimina.", fileName: "screenshot-delete-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "screenshot-delete-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1

        // Real subview of `pdfView` (as in production, `PDFKitView.swift`), but
        // NEVER inside an `NSWindow` — also tried with a real window, same result
        // for the button (see comment above), so the simplest version, with no
        // crash risk, is kept.
        let annotationOverlay = AnnotationOverlayView(model: model, pdfView: pdfView)
        annotationOverlay.frame = pdfView.bounds
        pdfView.addSubview(annotationOverlay)

        let controller = model.annotationController
        controller.barVisible = true
        // Near the top-right corner of the page (200 pt tall): this way the
        // button, at the top right of the icon, lands in a distinctive spot that
        // is easy to find in the screenshot.
        let note = controller.createNote(page: 0, at: CGPoint(x: 220, y: 150))
        controller.selectTool(.select)
        controller.selectedId = note.id // selected → the button is visible (SPEC "selected OR under the mouse")

        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let pngURL = outputRoot.appendingPathComponent("nota-bottone-elimina.png")
        exportPNG(pdfView, to: pngURL)

        // REAL re-read from disk (not the in-memory view): the file must exist,
        // have sensible dimensions, and contain somewhere the color of the
        // button's circle (`DSColor.accent`, `+DeleteButton.swift`) — otherwise
        // the saved PNG does not show the button at all, even if the in-memory
        // view drew it correctly.
        let savedData = try Data(contentsOf: pngURL)
        #expect(savedData.count > 200, "the saved PNG is suspiciously small/empty")
        let rereadBitmap = try #require(NSBitmapImageRep(data: savedData), "the saved file must be a valid PNG readable by NSBitmapImageRep")
        #expect(rereadBitmap.pixelsWide > 0 && rereadBitmap.pixelsHigh > 0)

        // Scan of the ENTIRE image, not just the expected corner: the Y-axis
        // convention of `NSBitmapImageRep.colorAt` relative to PDFKit's page space
        // is not guaranteed (same warning already noted in
        // `SidebarIndexLegendRenderTests`), so we do not assume which side of the
        // PNG the button falls on — only that it is there, somewhere.
        let expectedAccent = try #require(NSColor(DSColor.accent).usingColorSpace(.deviceRGB))
        var found = false
        let steps = 60
        outer: for xStep in 0 ... steps {
            for yStep in 0 ... steps {
                let x = min(Int(CGFloat(rereadBitmap.pixelsWide) * CGFloat(xStep) / CGFloat(steps)), rereadBitmap.pixelsWide - 1)
                let y = min(Int(CGFloat(rereadBitmap.pixelsHigh) * CGFloat(yStep) / CGFloat(steps)), rereadBitmap.pixelsHigh - 1)
                guard let sampled = rereadBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if colorsClose(sampled, expectedAccent) { found = true; break outer }
            }
        }
        #expect(found, "the delete button color (\(expectedAccent)) is nowhere to be found in the PNG re-read from \(pngURL.path) — the button does not appear to be drawn in the saved file")
    }

    private func colorsClose(_ a: NSColor, _ b: NSColor, tolerance: CGFloat = 0.15) -> Bool {
        abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }
}
}
