import AppKit

/// Note popover (SPEC §5.13 "click on the icon → popover with a multi-line
/// text editor, Preview style"): a plain `NSTextView` inside an
/// `NSScrollView`, without TextKit 2 (the marks' hover is not needed here,
/// just free text). The text is saved when the popover closes (SPEC "empty
/// note on close → delete", see `AnnotationController.updateNoteText`).
@MainActor
final class AnnotationNotePopoverController: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 140))
    private let annotationId: String
    private weak var annotationController: AnnotationController?

    init(annotation: Annotation, controller: AnnotationController) {
        annotationId = annotation.id
        annotationController = controller
        super.init()
        textView.string = annotation.text ?? ""
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 6, height: 6)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let viewController = NSViewController()
        viewController.view = scrollView
        popover.contentViewController = viewController
        popover.contentSize = NSSize(width: 240, height: 160)
        popover.behavior = .transient
        popover.delegate = self
    }

    func show(from view: NSView, at rect: NSRect) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        view.window?.makeFirstResponder(textView)
    }

    func popoverWillClose(_ notification: Notification) {
        annotationController?.updateNoteText(id: annotationId, text: textView.string)
    }
}
