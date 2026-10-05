import Foundation

/// Resolution of the `{{mX|words}}` markers of a `RewriteItem` into
/// `AnalysisController.ResolvedRewriteItem`/`ResolvedSegment` (SPEC §7.5
/// point 12). Extracted from `AnalysisController` for the Summary Lab: pure,
/// independent of the open document's context, so the Lab can also resolve a
/// new attempt (an `AnalysisPostProcessor.Output` never saved in
/// `analisi.json`) with the same logic used for real cards.
enum RewriteResolution {
    static func resolve(
        _ item: RewriteItem, marksById: [String: Mark], manualMarks: [Mark] = []
    ) -> AnalysisController.ResolvedRewriteItem {
        func segments(_ text: String) -> [AnalysisController.ResolvedSegment] {
            ManualMarks.highlightManualTerms(in: resolveSegments(text, marksById: marksById), manualMarks: manualMarks)
        }
        // Only `kind == .outline` populates `lines` (`.bullets` stays on its
        // own existing `itemSegments`/`subItemSegments`, unchanged).
        let resolvedLines: [AnalysisController.ResolvedLine]? = item.kind == .outline
            ? RewriteOutlineReader.lines(for: item).map { line in
                AnalysisController.ResolvedLine(type: line.type, segments: segments(line.text))
            }
            : nil
        return AnalysisController.ResolvedRewriteItem(
            kind: item.kind,
            segments: item.text.map(segments),
            itemSegments: item.items?.map(segments),
            subItemSegments: item.subItems?.map { subs in subs.map(segments) },
            columns: item.columns,
            rowSegments: item.rows?.map { row in row.map(segments) },
            lines: resolvedLines
        )
    }

    private static let markerPattern = #"\{\{([^|}]+)\|([^}]*)\}\}"#

    static func resolveSegments(_ text: String, marksById: [String: Mark]) -> [AnalysisController.ResolvedSegment] {
        guard text.contains("{{") else { return [.plain(text)] }
        var segments: [AnalysisController.ResolvedSegment] = []
        var remaining = Substring(text)
        while let range = remaining.range(of: markerPattern, options: .regularExpression) {
            if range.lowerBound > remaining.startIndex {
                segments.append(.plain(String(remaining[remaining.startIndex ..< range.lowerBound])))
            }
            let token = remaining[range]
            let inner = token.dropFirst(2).dropLast(2)
            if let barIndex = inner.firstIndex(of: "|") {
                let id = String(inner[inner.startIndex ..< barIndex])
                let shown = String(inner[inner.index(after: barIndex)...])
                if let mark = marksById[id], !mark.hidden {
                    segments.append(.marked(text: shown, markId: mark.id, termId: mark.termId, type: mark.type))
                } else {
                    segments.append(.plain(shown))
                }
            }
            remaining = remaining[range.upperBound...]
        }
        if !remaining.isEmpty { segments.append(.plain(String(remaining))) }
        return segments
    }

    /// Card ready for rendering (`RewriteItemView`) from an
    /// `AnalysisPostProcessor` output that has not been saved yet (Summary Lab
    /// new attempt). Same shape as `AnalysisController.cardData`, but without
    /// needing a block already present in `analisi.json`.
    static func card(from output: AnalysisPostProcessor.Output) -> AnalysisController.BlockCardData {
        let marksById = Dictionary(output.marks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return AnalysisController.BlockCardData(
            title: output.title,
            rewrite: output.rewrite.map { resolve($0, marksById: marksById) },
            page: 0,
            pageEnd: 0,
            edited: false
        )
    }
}
