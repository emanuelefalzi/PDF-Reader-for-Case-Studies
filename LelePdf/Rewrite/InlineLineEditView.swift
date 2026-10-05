import SwiftUI

/// In-place editing of ONE line of a card (replaces the earlier
/// whole-card blob editor): same typography as the read-only line
/// (`fontSize`/`italic`/`serif`, the same parameters passed to
/// `MarkedTextView` for that line type), caret where the user triple-clicked
/// (`initialCaret`; `nil` = start of text, used when opened from the "Edit
/// text" menu). `onSave`/`onCancel` come from the underlying
/// `EditableMarkedNSTextView` (⌘↩ / Esc / focus loss), not from a SwiftUI
/// button: there is no on-screen "Save"/"Cancel", by design (triple-click,
/// type, ⌘↩).
struct InlineLineEditView: NSViewRepresentable {
    let initialText: String
    let initialSpans: [RewriteEditText.MarkSpan]
    let initialCaret: Int?
    var fontSize: CGFloat
    var italic: Bool = false
    var serif: Bool = false
    let onSave: (String, [RewriteEditText.MarkSpan]) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> EditableMarkedNSTextView {
        let view = EditableMarkedNSTextView()
        view.configureFont(size: fontSize, italic: italic, serif: serif)
        view.setInitialContent(text: initialText, spans: initialSpans)
        view.placeCaret(at: initialCaret)
        view.onSave = { [weak view] in
            guard let view else { return }
            let content = view.currentContent()
            onSave(content.text, content.spans)
        }
        view.onCancel = onCancel
        // Take real focus on the next RunLoop turn: the view needs a window
        // first (SwiftUI has just created it and has not inserted it into
        // the hierarchy yet at this point).
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: EditableMarkedNSTextView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditableMarkedNSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        guard let textContainer = nsView.textContainer, let layoutManager = nsView.layoutManager else {
            return CGSize(width: width, height: fontSize + 6)
        }
        textContainer.containerSize = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: width, height: max(fontSize + 6, used.height.rounded(.up) + 8))
    }
}
