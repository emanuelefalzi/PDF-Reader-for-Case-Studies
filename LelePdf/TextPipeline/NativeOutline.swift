import Foundation
@preconcurrency import PDFKit

/// Extracts a PDF's built-in outline (`PDFOutline`) into simple structures,
/// to be evaluated with `OutlineEvaluator` and shown as `TocEntry` (SPEC
/// §5.3). It stays on the MainActor because `PDFDocument`/`PDFOutline` are
/// not `Sendable`.
@MainActor
enum NativeOutline {
    /// Raw entries in visit order (pre-order), with level 1 for the root's
    /// direct children.
    static func extractRaw(from document: PDFDocument) -> [OutlineEvaluator.RawEntry] {
        guard let root = document.outlineRoot else { return [] }
        var result: [OutlineEvaluator.RawEntry] = []
        walk(root, level: 1, document: document, into: &result)
        return result
    }

    /// Entries ready for the Chapters sidebar, with a stable id and the level
    /// limited to 1-3 (SPEC §7.4).
    static func extractEntries(from document: PDFDocument) -> [TocEntry] {
        extractRaw(from: document).enumerated().map { index, raw in
            TocEntry(
                id: "native-\(index)",
                title: raw.title,
                level: min(max(raw.level, 1), 3),
                page: raw.page ?? 0,
                pageY: raw.pageY
            )
        }
    }

    private static func walk(
        _ outline: PDFOutline,
        level: Int,
        document: PDFDocument,
        into result: inout [OutlineEvaluator.RawEntry]
    ) {
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var page: Int?
            var pageY: Double?
            if let destination = child.destination, let destinationPage = destination.page {
                let resolved = document.index(for: destinationPage)
                page = resolved == NSNotFound ? nil : resolved
                // When the outline specifies no explicit point, the
                // destination's point often comes back as (0, 0) instead of
                // `nil`, indistinguishable via the PDFKit API from a real point
                // at the bottom of the page. `> 0` discards that ambiguous
                // case: it loses the rare entry that really points to the last
                // line of the page, but avoids sending every "pointless" entry
                // to the bottom of the wrong page (SPEC "keeps working without
                // a match"; the caller still falls back to the page jump
                // alone).
                let rawY = destination.point.y
                if page != nil, rawY.isFinite, rawY > 0 {
                    pageY = Double(rawY)
                }
            }
            result.append(OutlineEvaluator.RawEntry(title: title, level: level, page: page, pageY: pageY))
            walk(child, level: level + 1, document: document, into: &result)
        }
    }
}
