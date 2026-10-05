import AppKit
@preconcurrency import PDFKit

/// Text box editor and note popover (SPEC §5.13): extension kept separate
/// from `AnnotationOverlayView.swift` to keep files small.
@MainActor
extension AnnotationOverlayView {
    /// SPEC: "new text box starts with the placeholder text 'Text'
    /// selected" (string taken from Preview,
    /// `FreeTextAnnotationDefaultContents` in `Localizable.loctable`).
    static let textboxPlaceholder = "Text"

    func beginTextboxEditing(page: Int, origin: CGPoint) {
        activeTextBoxView?.removeFromSuperview()
        guard let pdfView, let pdfPage = pdfView.document?.page(at: page) else { return }
        let viewPoint = pdfView.convert(origin, from: pdfPage)
        let frame = CGRect(x: viewPoint.x, y: viewPoint.y - 14, width: 200, height: 30)
        let textView = AnnotationTextBoxTextView(frame: frame)
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.95)
        textView.string = Self.textboxPlaceholder
        addSubview(textView)
        textView.onCommit = { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.commitTextbox(textView, page: page)
        }
        textView.onCancel = { [weak self, weak textView] in
            textView?.removeFromSuperview()
            if let self, self.activeTextBoxView === textView { self.activeTextBoxView = nil }
        }
        window?.makeFirstResponder(textView)
        textView.selectAll(nil)
        activeTextBoxView = textView
    }

    private func commitTextbox(_ textView: AnnotationTextBoxTextView, page: Int) {
        defer {
            textView.removeFromSuperview()
            if activeTextBoxView === textView { activeTextBoxView = nil }
        }
        guard let pdfView, let pdfPage = pdfView.document?.page(at: page) else { return }
        let pageRect = pdfView.convert(textView.frame, to: pdfPage)
        controller?.createTextbox(page: page, rect: pageRect, text: textView.string)
    }

    /// SPEC "click the icon → popover with a multi-line text editor": opened
    /// right after the icon is created (SPEC "Note: click places a note
    /// icon"), and again by `AnnotationOverlayView+Mouse.swift` when the
    /// Select tool touches an already existing note icon.
    func presentNotePopover(for annotation: Annotation) {
        guard let controller, let pdfView, let pdfPage = pdfView.document?.page(at: annotation.page) else { return }
        let viewRect = pdfView.convert(annotation.rect.cgRect, from: pdfPage)
        let popoverController = AnnotationNotePopoverController(annotation: annotation, controller: controller)
        activeNotePopover = popoverController
        popoverController.show(from: self, at: viewRect)
    }
}
