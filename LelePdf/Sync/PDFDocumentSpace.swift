import AppKit
@preconcurrency import PDFKit

/// Conversions from PDF page space to the common document space
/// (`DocumentSpace`), to build the PDF-side segments (`AlignmentBuilder`).
/// Extension of `PDFReaderBridge` (Reader) kept in `Sync/` because it is
/// sync code, not reader code: `pdfView` is readable from here
/// (`private(set)`, not `private`).
@MainActor
extension PDFReaderBridge {
    /// PDFKit's `documentView` below the `PDFView`: it is the same view as
    /// `enclosingScrollView.documentView`; the name here just makes explicit
    /// what it is used for.
    var pdfDocumentView: NSView? { pdfView?.documentView }

    /// Vertical span (document space, scrolling downward) of a rectangle in
    /// page space. `nil` if the page/view are not ready (document still
    /// loading).
    func topDownSpan(pageRect: CGRect, page: PDFPage) -> (top: CGFloat, bottom: CGFloat)? {
        guard let pdfView, let documentView = pdfView.documentView else { return nil }
        let inViewport = pdfView.convert(pageRect, from: page)
        let inDocument = pdfView.convert(inViewport, to: documentView)
        if documentView.isFlipped {
            return (inDocument.minY, inDocument.maxY)
        }
        let docHeight = documentView.bounds.height
        return (docHeight - inDocument.maxY, docHeight - inDocument.minY)
    }

    /// Extent of the whole page (for the anchor points of titles and
    /// Exhibits, which have no rectangle of their own; SPEC §5.8, see
    /// `AlignmentBuilder`).
    func topDownPageSpan(pageIndex: Int) -> (top: CGFloat, bottom: CGFloat)? {
        guard let pdfView, let document = pdfView.document, let page = document.page(at: pageIndex) else { return nil }
        return topDownSpan(pageRect: page.bounds(for: .mediaBox), page: page)
    }
}
