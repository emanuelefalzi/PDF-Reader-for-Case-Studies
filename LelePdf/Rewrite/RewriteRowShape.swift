import Foundation

/// Lightweight shape of a right-hand panel row (part of the lazy panel):
/// everything needed to ESTIMATE the height of a row that has not been built
/// yet and to notice when its content has changed (the shape also serves as
/// the signature of the measured-height cache, see `RewritePanelGeometry`).
/// It is built from the saved `BlockAnalysis` alone (character counts, never
/// resolved text or marks): it costs microseconds per row, so it can be
/// rebuilt on every panel evaluation.
enum RewriteRowShape: Hashable, Sendable {
    case heading(level: Int)
    case exhibit
    case orphan
    /// Block not analyzed (or queued / in progress / failed): SPEC §5.6
    /// "minimum height of 44 pt".
    case placeholder
    case card(items: [ItemShape])

    struct ItemShape: Hashable, Sendable {
        var kind: RewriteKind
        /// Character count of the text (`summary`/`paragraph`/`definition`/`callout`).
        var chars: Int = 0
        /// Characters per line (`bullets`/`steps`) or number of rows (`table`,
        /// one element per row holding the largest cell character count).
        var lines: [Int] = []
        /// Characters per sub-point (`bullets` only), flattened.
        var subLines: [Int] = []
        var columns: Int = 0
        /// Only for `kind == .outline`: one entry per rewrite line (same
        /// order as `RewriteOutlineReader.lines(for:)`).
        var outlineLines: [OutlineLineShape] = []
    }

    /// Lightweight shape of a single `kind == .outline` line: only the type
    /// (heights and indents differ per type, see `RewriteRowHeightEstimator`)
    /// and the character count.
    struct OutlineLineShape: Hashable, Sendable {
        var type: RewriteLineType
        var chars: Int
    }

    static func shape(for row: RewriteRow, analysis: BlockAnalysis?) -> RewriteRowShape {
        switch row {
        case .heading(_, _, let level, _): return .heading(level: level)
        case .exhibit: return .exhibit
        case .orphan: return .orphan
        case .block:
            guard let analysis, analysis.status == .analyzed else { return .placeholder }
            return .card(items: analysis.rewrite.map(ItemShape.init(item:)))
        }
    }
}

extension RewriteRowShape.ItemShape {
    init(item: RewriteItem) {
        kind = item.kind
        switch item.kind {
        case .summary, .paragraph, .definition, .callout:
            chars = item.text?.count ?? 0
        case .bullets, .steps:
            lines = (item.items ?? []).map(\.count)
            subLines = (item.subItems ?? []).flatMap { $0.map(\.count) }
        case .table:
            columns = item.columns?.count ?? 0
            lines = (item.rows ?? []).map { $0.map(\.count).max() ?? 0 }
        case .outline:
            outlineLines = RewriteOutlineReader.lines(for: item).map { RewriteRowShape.OutlineLineShape(type: $0.type, chars: $0.text.count) }
        }
    }
}

/// Estimates the height of a row at a given width: used ONLY until the row
/// has actually been built and measured; after that the measurement wins
/// (`RewritePanelGeometry`). The constants follow the fonts, spacing and
/// padding of `BlockCardView`/`RewriteItemView`/`CardContainer`/
/// `BlockPlaceholderView`. A wrong estimate never produces a visible error
/// on screen (visible rows are always measured); it only gives an
/// approximate position in the alignment model (SPEC §5.8) for rows never
/// seen, and a slightly imprecise scroll bar until they are built.
enum RewriteRowHeightEstimator {
    static let placeholderHeight: CGFloat = RewriteViewModel.placeholderMinHeight
    static let cardPadding: CGFloat = 24
    static let cardHeader: CGFloat = 16
    static let cardItemSpacing: CGFloat = 8

    static func estimate(_ shape: RewriteRowShape, width: CGFloat) -> CGFloat {
        switch shape {
        case .heading(let level): return level == 1 ? 28 : 20
        case .exhibit: return 28
        case .orphan: return 44
        case .placeholder: return placeholderHeight
        case .card(let items):
            let textWidth = max(80, width - 26)
            let body = items.reduce(CGFloat(0)) { $0 + estimate($1, textWidth: textWidth) }
            return cardPadding + cardHeader + body + cardItemSpacing * CGFloat(max(0, items.count - 1))
        }
    }

    private static func lineHeight(_ font: CGFloat) -> CGFloat { font * 1.2 + 4 }

    private static func lines(_ chars: Int, font: CGFloat, width: CGFloat) -> CGFloat {
        let perLine = max(8, width / (font * 0.5))
        return max(1, (CGFloat(chars) / perLine).rounded(.up))
    }

    private static func estimate(_ item: RewriteRowShape.ItemShape, textWidth: CGFloat) -> CGFloat {
        switch item.kind {
        case .summary:
            return lines(item.chars, font: 13, width: textWidth) * lineHeight(13)
        case .paragraph:
            return lines(item.chars, font: 12.5, width: textWidth) * lineHeight(12.5)
        case .definition:
            return 20 + 12 + 6 + lines(item.chars, font: 12.5, width: textWidth - 20) * lineHeight(12.5)
        case .callout:
            return 18 + lines(item.chars, font: 12, width: textWidth - 18) * lineHeight(12)
        case .bullets:
            let main = item.lines.reduce(CGFloat(0)) { $0 + lines($1, font: 12.5, width: textWidth - 12) * lineHeight(12.5) }
            let subs = item.subLines.reduce(CGFloat(0)) { $0 + lines($1, font: 11.5, width: textWidth - 31) * lineHeight(11.5) + 3 }
            return main + subs + 11 * CGFloat(max(0, item.lines.count - 1))
        case .steps:
            let main = item.lines.reduce(CGFloat(0)) { $0 + lines($1, font: 12.5, width: textWidth - 23) * lineHeight(12.5) }
            return main + 6 * CGFloat(max(0, item.lines.count - 1))
        case .table:
            return 4 + (item.columns > 0 ? 18 : 0) + CGFloat(item.lines.count) * 18
        case .outline:
            return item.outlineLines.reduce(CGFloat(0)) { total, line in total + estimate(line, textWidth: textWidth) }
                + 8 * CGFloat(max(0, item.outlineLines.count - 1))
        }
    }

    /// Height of a `kind == .outline` line, by type. Same idea as
    /// `estimate(_:textWidth:)` above for the point/sub-point types (indent
    /// and bullet, reduced usable width), plus the note/formula box (border
    /// and vertical spacing) and only top spacing for the subheading.
    private static func estimate(_ line: RewriteRowShape.OutlineLineShape, textWidth: CGFloat) -> CGFloat {
        switch line.type {
        case .point, .consequence, .other:
            return lines(line.chars, font: 12.5, width: textWidth - 12) * lineHeight(12.5)
        case .subpoint, .explanation:
            return lines(line.chars, font: 11.5, width: textWidth - 31) * lineHeight(11.5) + 3
        case .note, .definition:
            return 18 + lines(line.chars, font: 12, width: textWidth - 18) * lineHeight(12)
        case .example:
            return 18 + lines(line.chars, font: 11, width: textWidth - 18) * lineHeight(11)
        case .formula:
            return 20 + lines(line.chars, font: 12.5, width: textWidth - 20) * lineHeight(12.5)
        case .subheading:
            return 4 + lineHeight(11.5)
        }
    }
}
