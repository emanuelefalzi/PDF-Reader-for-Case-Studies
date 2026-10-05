import AppKit

/// Editable `NSTextView` for "Edit text" (SPEC §5.6): marks are a custom text
/// attribute (`markIdAttribute`) that follows typing and deletion through the
/// default behavior of `NSTextStorage` (SPEC "if you retype them the mark
/// follows, if you delete them the mark disappears"). No dedicated code is
/// needed here: it is simply how `NSAttributedString` extends, shrinks or
/// removes an attribute when editing inside, at the edges of, or beyond a
/// range. While typing it draws a neutral background over the marked text.
/// This is deliberately not the exact color of the mark type, which would
/// need a second parallel attribute just for that; the real color returns as
/// soon as editing ends, when the card re-reads `analisi.json` through
/// `MarkedTextView`.
final class EditableMarkedNSTextView: NSTextView {
    static let markIdAttribute = NSAttributedString.Key("LelePdfMarkId")

    /// Called when the line must be saved: ⌘↩ (`keyDown`) or loss of focus
    /// for any other reason (`resignFirstResponder`; "a click outside saves"
    /// comes for free from the native responder chain). `onCancel`: Esc,
    /// "restore" instead of saving.
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Prevents a double call when ⌘↩/Esc have already acted explicitly and
    /// the view loses focus right afterwards (the view is removed from the
    /// SwiftUI hierarchy as soon as `editingLine` returns to `nil`).
    private var finished = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isEditable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = NSSize(width: 0, height: 4)
        container?.lineFragmentPadding = 0
        font = NSFont.systemFont(ofSize: 12.5)
        textColor = NSColor(DSColor.textPrimary)
        allowsUndo = true
    }

    /// Typography identical to the read-only line (`MarkedNSTextView.
    /// baseFont`, the same function but duplicated here, since it cannot be
    /// shared without exposing a public static method on a class that must
    /// know nothing about editing), with the same per-line italic/serif.
    func configureFont(size: CGFloat, italic: Bool, serif: Bool) {
        var newFont: NSFont
        if serif, let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif),
           let serifFont = NSFont(descriptor: descriptor, size: size) {
            newFont = serifFont
        } else {
            newFont = .systemFont(ofSize: size)
        }
        if italic {
            newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .italicFontMask)
        }
        font = newFont
        typingAttributes[.font] = newFont
    }

    /// Caret where the user triple-clicked (UTF-16 offset in the displayed
    /// text, same coordinate system as `MarkSpan`/the `marks.first` hit test
    /// in `MarkedNSTextView.mouseDown`), or start of text if unavailable
    /// (opened from the "Edit text" menu).
    func placeCaret(at offset: Int?) {
        let length = (string as NSString).length
        let clamped = max(0, min(offset ?? 0, length))
        setSelectedRange(NSRange(location: clamped, length: 0))
    }

    /// ⌘↩ saves, Esc cancels; both are intercepted BEFORE `super.keyDown`, so
    /// they never become a newline or an empty character in the text.
    /// Arrows/⇧+arrows/⌘A/⌘C/⌘V/⌘X/⌘Z keep the default `NSTextView`/
    /// `UndoManager` behavior (`allowsUndo = true`) and are never intercepted
    /// here.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "\r" {
            triggerSave()
            return
        }
        if event.charactersIgnoringModifiers == "\u{1b}" {
            triggerCancel()
            return
        }
        super.keyDown(with: event)
    }

    /// "A click outside saves": AppKit always calls `resignFirstResponder` on
    /// this view BEFORE moving focus to any other view in the same window
    /// (another line being edited, a button, the PDF...), so no global click
    /// mechanism has to be built by hand.
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, !finished {
            triggerSave()
        }
        return result
    }

    private func triggerSave() {
        guard !finished else { return }
        finished = true
        onSave?()
    }

    private func triggerCancel() {
        guard !finished else { return }
        finished = true
        onCancel?()
    }

    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Initial text plus marks (from `RewriteEditText.render`): applies the
    /// custom attributes on top of the plain text, so later edits follow them
    /// automatically.
    func setInitialContent(text: String, spans: [RewriteEditText.MarkSpan]) {
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: textColor ?? NSColor.labelColor,
        ])
        for span in spans {
            guard let utf16Range = Self.utf16Range(fromCharacterRange: span.range, in: text) else { continue }
            attributed.addAttribute(Self.markIdAttribute, value: span.markId, range: utf16Range)
        }
        textStorage?.setAttributedString(attributed)
    }

    /// Current text plus marks, read from the custom attribute with
    /// `enumerateAttribute` (one contiguous range = one mark).
    func currentContent() -> (text: String, spans: [RewriteEditText.MarkSpan]) {
        guard let storage = textStorage else { return ("", []) }
        let text = storage.string
        var spans: [RewriteEditText.MarkSpan] = []
        storage.enumerateAttribute(Self.markIdAttribute, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard let markId = value as? String,
                  let characterRange = Self.characterRange(fromUTF16Range: range, in: text)
            else { return }
            spans.append(RewriteEditText.MarkSpan(range: characterRange, markId: markId))
        }
        return (text, spans)
    }

    /// `RewriteEditText` and `Mark.range` use `Character` offsets, while
    /// AppKit/`NSAttributedString` uses UTF-16. Converting at the editor
    /// boundary keeps emoji or composed graphemes before a mark from shifting
    /// its attribute (or pushing it out of range).
    private static func utf16Range(fromCharacterRange range: NSRange, in text: String) -> NSRange? {
        guard range.location >= 0, range.length >= 0,
              range.location + range.length <= text.count
        else { return nil }
        let start = text.index(text.startIndex, offsetBy: range.location)
        let end = text.index(start, offsetBy: range.length)
        return NSRange(start ..< end, in: text)
    }

    private static func characterRange(fromUTF16Range range: NSRange, in text: String) -> NSRange? {
        guard let stringRange = Range(range, in: text) else { return nil }
        let location = text.distance(from: text.startIndex, to: stringRange.lowerBound)
        let length = text.distance(from: stringRange.lowerBound, to: stringRange.upperBound)
        return NSRange(location: location, length: length)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawMarkBackgrounds()
        super.draw(dirtyRect)
    }

    private func drawMarkBackgrounds() {
        guard let layoutManager, let textContainer, let storage = textStorage,
              let context = NSGraphicsContext.current?.cgContext else { return }
        storage.enumerateAttribute(Self.markIdAttribute, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard value is String else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rects: [NSRect] = []
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                rects.append(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
            }
            guard !rects.isEmpty else { return }
            context.saveGState()
            context.setFillColor(NSColor(DSColor.accentBackground).cgColor)
            for rect in rects { context.fill(rect.insetBy(dx: -1, dy: -1)) }
            context.restoreGState()
        }
    }
}
