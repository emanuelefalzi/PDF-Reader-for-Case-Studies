import AppKit
@preconcurrency import PDFKit

/// Highlight/underline/strikethrough "by dragging" (SPEC §5.13 "drag over
/// the text and it stays highlighted"). The overlay's events are used up to
/// `mouseUp`: the native target is a private `PDFPageView` that loses the
/// first click of a non-key window, while the selection notification can
/// arrive when the drag is still partial. `PDFDocument` exposes the same
/// point-to-point selection, without depending on those private details.
@MainActor
extension AnnotationOverlayView {
    func handleTextMarkupSelectionChanged() {
        guard !isHandlingTextMarkupDrag,
              let controller, controller.barVisible, controller.tool.isTextMarkup,
              let kind = controller.tool.kind,
              let pdfView, let selection = pdfView.currentSelection,
              let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let document = pdfView.document else { return }

        AnnotationTextMarkupCreator.apply(kind: kind, selection: selection, document: document, controller: controller)
        // Preview: after highlighting, the selection disappears and the tool
        // stays ready for the next drag.
        pdfView.clearSelection()
    }

    func beginTextMarkupDrag(page: Int, point: CGPoint) {
        guard let document = pdfView?.document, let startPage = document.page(at: page) else { return }
        isHandlingTextMarkupDrag = true
        textMarkupStartPage = startPage
        textMarkupStartPoint = point
        pdfView?.clearSelection()
    }

    func updateTextMarkupDrag(page: Int, point: CGPoint) {
        guard isHandlingTextMarkupDrag,
              let document = pdfView?.document,
              let startPage = textMarkupStartPage,
              let startPoint = textMarkupStartPoint,
              let endPage = document.page(at: page),
              let selection = document.selection(from: startPage, at: startPoint, to: endPage, at: point)
        else { return }
        pdfView?.setCurrentSelection(selection, animate: false)
    }

    func finishTextMarkupDrag(end: (page: Int, point: CGPoint)?) {
        defer {
            pdfView?.clearSelection()
            textMarkupStartPage = nil
            textMarkupStartPoint = nil
            isHandlingTextMarkupDrag = false
        }
        guard isHandlingTextMarkupDrag,
              let controller,
              let kind = controller.tool.kind,
              let document = pdfView?.document,
              let startPage = textMarkupStartPage,
              let startPoint = textMarkupStartPoint,
              let end,
              let endPage = document.page(at: end.page),
              let selection = document.selection(from: startPage, at: startPoint, to: endPage, at: end.point),
              let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        AnnotationTextMarkupCreator.apply(
            kind: kind, selection: selection, document: document, controller: controller
        )
    }
}
