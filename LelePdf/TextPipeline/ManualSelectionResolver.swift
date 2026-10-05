import Foundation
@preconcurrency import PDFKit

/// Inverse of `TextBlock.resolve(cleanRange:)` (M7 deliverable 1: resolve
/// the PDFSelection → page char ranges → the containing block and its clean
/// range): from the user's selection in the PDF to the block touched and to
/// the corresponding range in its clean text, to create a manual mark (SPEC
/// §5.7) or a manual contents entry (v2.3 §5.3).
@MainActor
enum ManualSelectionResolver {
    struct Resolution: Sendable, Equatable {
        var blockId: String
        var cleanRange: NSRange
        /// Exact text copied from the block (the same rule as SPEC §7.5,
        /// taken from `cleanText` in the range found, not from the
        /// selection's raw text, which PDFKit sometimes spaces differently;
        /// see `BlockSelectionRoundTripTests`).
        var text: String
        var page: Int
    }

    /// [M7-3]: a selection straddling several pages or several blocks is
    /// trimmed to the **first** block/page touched; a mark never crosses a
    /// block boundary (SPEC §7.3 only covers the case "straddling two pages
    /// of the same block", not two different blocks).
    static func resolve(selection: PDFSelection, document: PDFDocument, blocks: [TextBlock]) -> Resolution? {
        guard let firstPage = selection.pages.first else { return nil }
        let pageIndex = document.index(for: firstPage)
        guard pageIndex != NSNotFound else { return nil }
        guard let origRange = originalRange(of: selection, onPage: firstPage) else { return nil }
        return resolve(page: pageIndex, originalRange: origRange, blocks: blocks)
    }

    /// Pure part of the resolution, separate from the PDFKit extraction so
    /// it can also cover pages that contain several blocks. The first block
    /// that really maps at least one character of the selection wins:
    /// checking only `pageStart...pageEnd` would make any selection belonging
    /// to the second (or later) block of the page fail.
    static func resolve(page: Int, originalRange: NSRange, blocks: [TextBlock]) -> Resolution? {
        guard let pair = blocks.lazy.compactMap({ block -> (TextBlock, NSRange)? in
            guard block.pageStart <= page, page <= block.pageEnd,
                  let cleanRange = block.inverseResolve(page: page, origRange: originalRange)
            else { return nil }
            return (block, cleanRange)
        }).first else { return nil }
        let (block, cleanRange) = pair
        let cleanCharacters = Array(block.cleanText)
        guard cleanRange.location >= 0, cleanRange.length > 0,
              cleanRange.location + cleanRange.length <= cleanCharacters.count else { return nil }
        let text = String(cleanCharacters[cleanRange.location ..< cleanRange.location + cleanRange.length])
        return Resolution(blockId: block.id, cleanRange: cleanRange, text: text, page: page)
    }

    /// Vertical position of the selection in page space (v2.3 §8 `pageY`):
    /// the top of the first line's rectangle on the first page, used to order
    /// several T1-T4 headings on the same page.
    static func pageY(of selection: PDFSelection, onPage page: PDFPage) -> Double? {
        let lines = selection.selectionsByLine().filter { $0.pages.contains(page) }
        guard let first = lines.first else { return nil }
        return Double(first.bounds(for: page).maxY)
    }

    /// Range of **original** characters (`page.string`) covered by the
    /// selection on `page` (the same technique as `LineExtractor`: searching
    /// each line's text inside `page.string` with a monotonic cursor, because
    /// PDFKit does not directly expose an `NSRange` from a `PDFSelection`).
    ///
    /// Selecting the second of two identical texts on the same page: unlike
    /// `LineExtractor`, which applies this same technique to ALL
    /// the lines of the page in reading order, so that a monotonic cursor
    /// alone is enough to disambiguate repeated lines, here only the few
    /// lines of the user's selection are searched, always starting from
    /// `searchStart`: if the selected phrase appears more than once on the
    /// page, the text search alone always finds the FIRST occurrence, not the
    /// one the user really selected. `matchingRange` resolves the ambiguity by
    /// comparing the geometric position of each candidate occurrence with the
    /// selection's true one.
    private static func originalRange(of selection: PDFSelection, onPage page: PDFPage) -> NSRange? {
        guard let pageString = page.string as NSString? else { return nil }
        let lineSelections = selection.selectionsByLine().filter { $0.pages.contains(page) }
        guard !lineSelections.isEmpty else { return nil }

        var searchStart = 0
        var minLocation = Int.max
        var maxUpper = 0
        for lineSelection in lineSelections {
            guard let lineText = lineSelection.string, !lineText.isEmpty else { continue }
            guard let found = matchingRange(of: lineText, in: pageString, on: page, matching: lineSelection, searchStart: searchStart) else { continue }
            minLocation = min(minLocation, found.location)
            maxUpper = max(maxUpper, found.location + found.length)
            searchStart = found.location + found.length
        }
        guard minLocation != Int.max, maxUpper > minLocation else { return nil }
        return NSRange(location: minLocation, length: maxUpper - minLocation)
    }

    /// Among all the occurrences of `lineText` in `pageString` starting from
    /// `searchStart`, it picks the one whose geometric position on the page
    /// really matches `lineSelection`, never simply the first found in the
    /// raw text when there is more than one. With a single occurrence the
    /// behavior stays identical to before (no extra cost in the common case,
    /// no geometry computed).
    private static func matchingRange(of lineText: String, in pageString: NSString, on page: PDFPage, matching lineSelection: PDFSelection, searchStart: Int) -> NSRange? {
        var candidates: [NSRange] = []
        var cursor = searchStart
        while cursor <= pageString.length {
            let found = pageString.range(of: lineText, options: [], range: NSRange(location: cursor, length: pageString.length - cursor))
            guard found.location != NSNotFound else { break }
            candidates.append(found)
            cursor = found.location + found.length
        }
        guard candidates.count > 1 else { return candidates.first }
        let targetBounds = lineSelection.bounds(for: page)
        return candidates.min { lhs, rhs in
            distance(from: geometricBounds(of: lhs, on: page), to: targetBounds)
                < distance(from: geometricBounds(of: rhs, on: page), to: targetBounds)
        }
    }

    /// Rectangle on the page of a candidate range of `page.string`, through
    /// `PDFPage.selection(for:)` (the same route as `LineExtractor`/
    /// `BlockSelectionResolver`, no character-by-character
    /// `characterBounds(at:)`).
    private static func geometricBounds(of range: NSRange, on page: PDFPage) -> CGRect {
        page.selection(for: range)?.bounds(for: page) ?? .zero
    }

    private static func distance(from rect: CGRect, to target: CGRect) -> CGFloat {
        let dx = rect.midX - target.midX
        let dy = rect.midY - target.midY
        return (dx * dx + dy * dy).squareRoot()
    }
}
