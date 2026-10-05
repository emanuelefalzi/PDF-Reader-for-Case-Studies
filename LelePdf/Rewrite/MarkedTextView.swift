import SwiftUI
import AppKit

/// Right-hand panel text with the 4 marks drawn as custom attributes
/// (SPEC §6.2 "Rewrite"): an `NSTextView` wrapped for SwiftUI, self-sizing,
/// that reports the index of the character under the mouse for linked hover
/// (SPEC §5.8).
///
/// [TECHNICAL CHOICE]: `NSTextView` with explicit `NSLayoutManager`/
/// `NSTextContainer` (TextKit 1 compatibility, not TextKit 2 as the SPEC
/// states as a preference). It gives direct access to
/// `enumerateEnclosingRects(forGlyphRange:...)` for the per-line rectangles
/// of the 4 marks (rectangle/circle/underline/arrow, with the same drawing
/// as `MarkGeometry`/`MarkPalette` used by the PDF overlay) and to
/// `characterIndex(for:in:...)` for hover, both mature TextKit 1 APIs;
/// TextKit 2 (`NSTextLayoutManager`) exposes no equally simple direct
/// equivalent for "line rectangles inside a range". Self-sizing is verified
/// with `sizeThatFits` (SPEC §6.2 "known risk"): no problems were found in
/// visual verification.
struct MarkedTextView: NSViewRepresentable {
    let text: String
    let marks: [MarkedTextBuilder.MarkedRange]
    var fontSize: CGFloat = 13
    var textColor: NSColor = NSColor(DSColor.textPrimary)
    var lineSpacing: CGFloat = 4
    /// Italic for note/explanation/formula lines in the right-hand panel,
    /// matching the corresponding Word style.
    var italic: Bool = false
    /// The `formula` line uses a different typeface from the body (serif)
    /// rather than italic alone, so it stands out even without reading it.
    var serif: Bool = false
    let model: DocumentModel
    let blockId: String
    /// A triple-click on this line starts in-place editing; reported as the
    /// index of the character under the click (same coordinate system as
    /// `text`, so the caret lands exactly there, "cursor where clicked").
    /// `nil` = line not editable in this context (e.g. the Summary Lab
    /// preview, `LaboratorioColumnsView`), no triple-click hit test.
    var onTripleClick: ((Int) -> Void)?
    /// Occurrences of the right-hand panel search to highlight in this line
    /// (system find style), in the same coordinates as `marks`.
    var searchHighlightRanges: [NSRange] = []

    func makeNSView(context: Context) -> MarkedNSTextView {
        let view = MarkedNSTextView()
        view.model = model
        view.blockId = blockId
        return view
    }

    func updateNSView(_ nsView: MarkedNSTextView, context: Context) {
        PerfProbe.hit("swiftui.MarkedTextView.update")
        nsView.model = model
        nsView.blockId = blockId
        nsView.onTripleClick = onTripleClick
        nsView.configure(text: text, marks: marks, fontSize: fontSize, textColor: textColor, lineSpacing: lineSpacing, italic: italic, serif: serif, searchHighlightRanges: searchHighlightRanges)
    }

    static func dismantleNSView(_ nsView: MarkedNSTextView, coordinator: ()) {
        nsView.stopObserving()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkedNSTextView, context: Context) -> CGSize? {
        // `PerfProbe`: TOTAL time spent here, including the `measuredSize`
        // cache. The difference between this and the cost of the whole layout
        // pass is inside SwiftUI (multiple proposals per view, nested
        // stacks), not in our code.
        return PerfProbe.measure("text.sizeThatFits") {
            let width = proposal.width ?? 300
            return nsView.measuredSize(forWidth: width)
        }
    }
}
