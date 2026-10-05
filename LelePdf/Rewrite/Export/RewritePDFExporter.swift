import AppKit

/// "PDF" (SPEC §8.2): a real PDF, generated from the same `NSAttributedString`
/// as "Copy with Formatting" (`RewriteExportAttributedString`), so it has the
/// same structure (headings, points, sub-points). Built with TextKit
/// (`NSLayoutManager`/`NSTextContainer`, one page = one `NSTextContainer`)
/// drawn into a PDF `CGContext`: no window, no `NSPrintOperation`. The
/// function is pure I/O (data comes in only through `RewriteExportDocument`),
/// so it can be tested without opening any UI (a test path with no save
/// panel).
///
/// The PDF of the open document (the one the user is reading) is never
/// touched: this is a NEW, separate file, never written over the original
/// (SPEC §8.2 "the PDF text ... is never modified by the export").
@MainActor
enum RewritePDFExporter {
    /// US Letter format (612×792 pt) with 54 pt margins: a size independent
    /// of the pages of the source PDF (the export is a document in its own
    /// right, not an overlay on the original pages).
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 54

    static func data(for document: RewriteExportDocument, pageSize: CGSize = pageSize, margin: CGFloat = margin, emphasizeMarkedTerms: Bool = false) -> Data? {
        let attributed = RewriteExportAttributedString.build(document, emphasizeMarkedTerms: emphasizeMarkedTerms)
        return renderPDF(attributed, pageSize: pageSize, margin: margin)
    }

    private static func renderPDF(_ attributed: NSAttributedString, pageSize: CGSize, margin: CGFloat) -> Data? {
        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let contentSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        let totalGlyphs = layoutManager.numberOfGlyphs
        var containers: [NSTextContainer] = []
        var laidOutGlyphs = 0
        // One `NSTextContainer` per page: `ensureLayout(for:)` fills it as far
        // as it fits, `glyphRange(for:)` says how much it consumed. If it
        // consumes nothing (empty text or a page that is too small) we stop,
        // to avoid an infinite loop.
        repeat {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            let range = layoutManager.glyphRange(for: container)
            containers.append(container)
            if range.length == 0 { break }
            laidOutGlyphs = NSMaxRange(range)
        } while laidOutGlyphs < totalGlyphs

        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        for container in containers {
            let glyphRange = layoutManager.glyphRange(for: container)
            context.beginPDFPage(nil)
            context.saveGState()
            NSGraphicsContext.saveGraphicsState()
            let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.current = nsContext
            // `NSLayoutManager` draws in a "top-down" system (origin at the top
            // left, like a flipped `NSView`); the PDF context has its origin
            // at the bottom left: translate to the top corner of the content
            // area and flip the Y axis.
            context.translateBy(x: margin, y: pageSize.height - margin)
            context.scaleBy(x: 1, y: -1)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return pdfData as Data
    }
}
