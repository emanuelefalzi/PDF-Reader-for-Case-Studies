import Foundation
@preconcurrency import PDFKit

/// Range of characters of `page.string` covered by one or more selection
/// lines (SPEC §8 `textRange?{start,length}`): same technique as
/// `LineExtractor`/`ManualSelectionResolver`: searching for each line's text
/// inside `page.string` with a monotonic cursor, because PDFKit does not
/// expose an `NSRange` directly from a `PDFSelection`.
@MainActor
enum AnnotationTextRangeResolver {
    /// As above, but starting from a rectangle in page space instead of a
    /// ready-made selection (so that it also works with annotations
    /// imported from Preview, which carry only `rect`/`quads` from the
    /// standard PDF values, never a `textRange`): `PDFPage.selection(for
    /// rect:)` (`selectionForRect:` in the Objective-C header) finds the
    /// enclosed text, then it proceeds as for any selection.
    static func range(for rect: CGRect, on page: PDFPage) -> AnnotationTextRange? {
        guard let selection = page.selection(for: rect) else { return nil }
        return range(forLines: selection.selectionsByLine(), page: page)
    }

    static func range(forLines lineSelections: [PDFSelection], page: PDFPage) -> AnnotationTextRange? {
        guard let pageString = page.string as NSString? else { return nil }
        var searchStart = 0
        var minLocation = Int.max
        var maxUpperBound = 0
        for lineSelection in lineSelections {
            guard let lineText = lineSelection.string, !lineText.isEmpty else { continue }
            let searchRange = NSRange(location: searchStart, length: pageString.length - searchStart)
            guard searchRange.length > 0 else { continue }
            let found = pageString.range(of: lineText, options: [], range: searchRange)
            guard found.location != NSNotFound else { continue }
            minLocation = min(minLocation, found.location)
            maxUpperBound = max(maxUpperBound, found.location + found.length)
            searchStart = found.location + found.length
        }
        guard minLocation != Int.max, maxUpperBound > minLocation else { return nil }
        return AnnotationTextRange(start: minLocation, length: maxUpperBound - minLocation)
    }
}
