import Foundation

/// Search in the right-hand panel (SPEC §5.10, also over the summary): pure,
/// on the ALREADY RESOLVED text that the card shows
/// (`AnalysisController.ResolvedRewriteItem`/`ResolvedSegment`, which went
/// through the clean text pipeline, never the raw `page.string`),
/// case-insensitive like the PDF search (`SearchService`).
enum RewriteSearch {
    /// True if the card's concatenated text contains `query` (the "n of N"
    /// count is at BLOCK level: a block is a result or it is not, not one
    /// result per exact occurrence, a deliberate simplification).
    static func matches(_ query: String, in items: [AnalysisController.ResolvedRewriteItem]) -> Bool {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return plainText(items).range(of: query, options: .caseInsensitive) != nil
    }

    /// TRUE occurrences of `query` inside ONE row (the same text that
    /// `MarkedTextView` draws for that row, with coordinates identical to
    /// `marks`/`MarkSpan`), for the on-screen highlighting: always exact when
    /// the card is built, unlike the count.
    static func highlightRanges(_ query: String, in segments: [AnalysisController.ResolvedSegment]) -> [NSRange] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let text = MarkedTextBuilder.build(segments).text as NSString
        guard text.length > 0 else { return [] }
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)
        while searchRange.length > 0 {
            let found = text.range(of: trimmed, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            let nextLocation = found.location + max(found.length, 1)
            guard nextLocation < text.length else { break }
            searchRange = NSRange(location: nextLocation, length: text.length - nextLocation)
        }
        return ranges
    }

    /// Concatenated plain text of ALL the fields of a card (item by item, row
    /// by row, markers already resolved), only for the "contains the query"
    /// comparison, never shown.
    private static func plainText(_ items: [AnalysisController.ResolvedRewriteItem]) -> String {
        var parts: [String] = []
        for item in items {
            if let segments = item.segments { parts.append(MarkedTextBuilder.build(segments).text) }
            for row in item.itemSegments ?? [] { parts.append(MarkedTextBuilder.build(row).text) }
            for subRows in item.subItemSegments ?? [] {
                for row in subRows { parts.append(MarkedTextBuilder.build(row).text) }
            }
            for row in item.rowSegments ?? [] {
                for cell in row { parts.append(MarkedTextBuilder.build(cell).text) }
            }
            for line in item.lines ?? [] { parts.append(MarkedTextBuilder.build(line.segments).text) }
        }
        return parts.joined(separator: "\n")
    }
}
