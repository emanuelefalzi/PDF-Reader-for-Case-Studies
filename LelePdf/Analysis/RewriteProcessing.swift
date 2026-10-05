import Foundation

/// Truncates (does not reject) tables beyond the limits of SPEC §5.6/§7.5
/// (post-processing, "≤ 8 rows/4 columns tables truncated not rejected"):
/// keeps the first rows/columns, a simpler choice than a selection "by
/// importance" that SPEC does not specify.
enum TableTruncation {
    static let maxColumns = 4
    static let maxRows = 8

    static func truncate(_ item: RewriteItem) -> RewriteItem {
        guard item.kind == .table else { return item }
        var copy = item
        if let columns = item.columns {
            copy.columns = Array(columns.prefix(maxColumns))
        }
        if let rows = item.rows {
            copy.rows = rows.prefix(maxRows).map { Array($0.prefix(maxColumns)) }
        }
        return copy
    }
}

/// Aligns `subItems` with `items` for a `bullets` element. Claude receives the
/// rule "one `subItems[i]` for each `items[i]`" in the prompt (`analysis.md`)
/// but the schema cannot enforce equal lengths on its own: here a shorter
/// `subItems` is completed with empty lists and a longer one is truncated, so
/// a slightly misaligned array never causes a valid main point to be dropped
/// nor shifts subpoints onto the wrong point.
enum BulletSubItemsNormalizer {
    static func align(_ item: RewriteItem) -> RewriteItem {
        guard item.kind == .bullets, let items = item.items, let subItems = item.subItems else { return item }
        var copy = item
        let aligned: [[String]]
        if subItems.count < items.count {
            aligned = subItems + Array(repeating: [], count: items.count - subItems.count)
        } else {
            aligned = Array(subItems.prefix(items.count))
        }
        // `nil` (not an array of all-empty lists) if no point really has
        // subpoints: keeps `RewriteItem` identical to a block without
        // subpoints, for backward compatibility of comparisons/tests.
        copy.subItems = aligned.allSatisfy(\.isEmpty) ? nil : aligned
        return copy
    }
}

/// Degrades in a controlled way (never a crash or an absurd hierarchy) a
/// sequence of `lines` that breaks the two rules the JSON schema cannot
/// enforce on its own, following the same principle as
/// `BulletSubItemsNormalizer` applied to the newer line types:
/// - a `subpoint`/`explanation` line BEFORE any `point`/`consequence`
///   (malformed text) becomes a `point` instead of staying orphaned or
///   skewing the hierarchy;
/// - more than one `explanation` under the same point (the prompt asks for at
///   most one, `analysis.md` rule 6): only the first stays an `explanation`,
///   the following ones become `subpoint` (they remain nested under the same
///   point, just rendered differently).
enum OutlineLinesNormalizer {
    static func align(_ item: RewriteItem) -> RewriteItem {
        guard item.kind == .outline, let lines = item.lines else { return item }
        var copy = item
        var result: [RewriteLine] = []
        var sawTopLevelLine = false
        var explanationSeenForCurrentPoint = false
        for line in lines {
            switch line.type {
            case .point, .consequence, .note, .formula, .subheading, .definition, .example:
                sawTopLevelLine = true
                explanationSeenForCurrentPoint = false
                result.append(line)
            case .subpoint:
                result.append(sawTopLevelLine ? line : RewriteLine(type: .point, text: line.text))
                if !sawTopLevelLine { sawTopLevelLine = true; explanationSeenForCurrentPoint = false }
            case .explanation:
                guard sawTopLevelLine else {
                    result.append(RewriteLine(type: .point, text: line.text))
                    sawTopLevelLine = true
                    explanationSeenForCurrentPoint = false
                    continue
                }
                if explanationSeenForCurrentPoint {
                    result.append(RewriteLine(type: .subpoint, text: line.text))
                } else {
                    result.append(line)
                    explanationSeenForCurrentPoint = true
                }
            case .other:
                result.append(line) // unknown value: let it through, rendered as a plain point (see `RewriteLineRowView`)
            }
        }
        copy.lines = result
        return copy
    }
}

/// `{{mX|shown words}}` markers in the rewrite text (SPEC §7.5 point 5): for
/// an unknown id or one dropped in post-processing, the braces are removed and
/// only the shown text remains; for a valid id the marker stays intact (the
/// card UI uses it to draw the mark in the text).
enum MarkerSanitizer {
    private static let markerPattern = #"\{\{([^|}]+)\|([^}]*)\}\}"#

    static func sanitize(_ text: String, keptMarkIds: Set<String>) -> String {
        guard text.contains("{{") else { return text }
        var result = ""
        var remaining = Substring(text)
        while let range = remaining.range(of: markerPattern, options: .regularExpression) {
            result += remaining[remaining.startIndex ..< range.lowerBound]
            result += renderToken(String(remaining[range]), keptMarkIds: keptMarkIds)
            remaining = remaining[range.upperBound...]
        }
        result += remaining
        return result
    }

    static func sanitize(_ item: RewriteItem, keptMarkIds: Set<String>) -> RewriteItem {
        var copy = item
        copy.text = item.text.map { sanitize($0, keptMarkIds: keptMarkIds) }
        copy.items = item.items?.map { sanitize($0, keptMarkIds: keptMarkIds) }
        copy.subItems = item.subItems?.map { subs in subs.map { sanitize($0, keptMarkIds: keptMarkIds) } }
        copy.columns = item.columns?.map { sanitize($0, keptMarkIds: keptMarkIds) }
        copy.rows = item.rows?.map { row in row.map { sanitize($0, keptMarkIds: keptMarkIds) } }
        // Lines of `kind == .outline`, same treatment as `items`.
        copy.lines = item.lines?.map { line in RewriteLine(type: line.type, text: sanitize(line.text, keptMarkIds: keptMarkIds)) }
        return copy
    }

    private static func renderToken(_ token: String, keptMarkIds: Set<String>) -> String {
        // token is "{{id|shown words}}".
        let inner = token.dropFirst(2).dropLast(2)
        guard let barIndex = inner.firstIndex(of: "|") else { return String(inner) }
        let id = String(inner[inner.startIndex ..< barIndex])
        let shown = String(inner[inner.index(after: barIndex)...])
        return keptMarkIds.contains(id) ? token : shown
    }
}

/// Rewrite as plain text, with markers always resolved to the shown words
/// (SPEC §7.6 Input: "the block's CURRENT rewrite ... as plain text with
/// marked terms already resolved to readable words"). Used by
/// `AnalysisController.regenerate` to build the input of the targeted
/// regeneration.
enum RewritePlainText {
    static func render(_ items: [RewriteItem]) -> String {
        items.map(renderItem).joined(separator: "\n\n")
    }

    private static func renderItem(_ item: RewriteItem) -> String {
        switch item.kind {
        case .summary, .paragraph, .callout, .definition:
            return strip(item.text ?? "")
        case .bullets:
            let items = item.items ?? []
            let subItems = item.subItems ?? []
            return items.enumerated().flatMap { index, text -> [String] in
                var lines = ["- " + strip(text)]
                if index < subItems.count {
                    lines.append(contentsOf: subItems[index].map { "  - " + strip($0) })
                }
                return lines
            }.joined(separator: "\n")
        case .steps:
            return (item.items ?? []).enumerated()
                .map { "\($0.offset + 1). " + strip($0.element) }
                .joined(separator: "\n")
        case .table:
            var lines: [String] = []
            if let columns = item.columns, !columns.isEmpty {
                lines.append(columns.map(strip).joined(separator: " | "))
            }
            lines.append(contentsOf: (item.rows ?? []).map { $0.map(strip).joined(separator: " | ") })
            return lines.joined(separator: "\n")
        case .outline:
            return RewriteOutlineReader.lines(for: item).map { line -> String in
                let prefix: String
                switch line.type {
                case .point: prefix = "- "
                case .subpoint: prefix = "  - "
                case .explanation: prefix = "  ~ "
                case .note: prefix = "note: "
                case .formula: prefix = "= "
                case .consequence: prefix = "-> "
                case .subheading: prefix = "## "
                case .definition: prefix = "def: "
                case .example: prefix = "ex: "
                case .other: prefix = "- "
                }
                return prefix + strip(line.text)
            }.joined(separator: "\n")
        }
    }

    /// Markers always resolved (no "kept" id): equivalent to a block with all
    /// marks dropped.
    private static func strip(_ text: String) -> String {
        MarkerSanitizer.sanitize(text, keptMarkIds: [])
    }
}
