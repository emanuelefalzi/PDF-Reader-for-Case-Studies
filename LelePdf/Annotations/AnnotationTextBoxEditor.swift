import AppKit

/// Raw `NSTextView` used for the text box editor (SPEC §5.13 "click on the
/// page, type directly"): commits when it loses first responder (click
/// elsewhere, Tab) or when Return is pressed; Esc cancels. A minimal
/// subclass rather than relying on the delegate alone, because
/// `textDidEndEditing` of an `NSTextView` not wrapped in a real text field
/// is not guaranteed on every exit path.
final class AnnotationTextBoxTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    private var committed = false
    private var cancelled = false

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, !committed, !cancelled {
            committed = true
            onCommit?()
        }
        return result
    }

    override func cancelOperation(_ sender: Any?) {
        cancelled = true
        onCancel?()
    }

    override func insertNewline(_ sender: Any?) {
        committed = true
        onCommit?()
    }
}
