import Foundation
@preconcurrency import PDFKit

/// Extracts the lines of a page with fonts, positions and superscript
/// digits (SPEC §7.1). It stays on the MainActor: `PDFPage`/
/// `NSAttributedString` are not `Sendable`.
///
/// It uses `PDFSelection.selectionsByLine()` for the line rectangles
/// (measured faster than `characterBounds(at:)` for every character across
/// the whole page), then searches each line's text inside `page.string` to
/// get the exact character range: the exact correspondence is needed because
/// the marks (M5) are carried back onto the PDF through those indices.
@MainActor
enum LineExtractor {
    static func extract(page: PDFPage, pageIndex: Int) -> PageLayout {
        extractWithText(page: page, pageIndex: pageIndex).layout
    }

    /// It also returns the raw text already read to build the layout. On long
    /// documents `PipelineRunner` keeps it only until the fingerprint is
    /// computed: it avoids a second full pass of `.string` over another 600
    /// `PDFPage` instances.
    static func extractWithText(page: PDFPage, pageIndex: Int) -> (layout: PageLayout, pageText: String) {
        let pageText = page.string ?? ""
        let fullText = pageText as NSString
        let fullLength = fullText.length
        let pageRect = page.bounds(for: .mediaBox)

        guard fullLength > 0,
              let fullSelection = page.selection(for: NSRange(location: 0, length: fullLength))
        else {
            return (
                PageLayout(pageIndex: pageIndex, pageRect: pageRect, lines: [], stringLength: fullLength),
                pageText
            )
        }

        let attributed = page.attributedString
        let lineSelections = fullSelection.selectionsByLine()
        // A single pass over the whole page: indices to
        // remove because they are duplicated by simulated bold/an extraction
        // defect ("Buuildingg the Teeam"). The vertical proximity check inside
        // `DuplicateGlyphCleaner` excludes different visual lines on its own,
        // so there is no need to redo the pass line by line.
        let dropped = DuplicateGlyphCleaner.duplicateIndices(page: page, text: fullText)

        var lines: [ExtractedLine] = []
        lines.reserveCapacity(lineSelections.count)
        var searchStart = 0

        for lineSelection in lineSelections {
            guard let rawLineString = lineSelection.string else { continue }
            let trimmed = rawLineString.trimmingCharacters(in: .newlines)
            guard !trimmed.isEmpty else { continue }
            guard searchStart < fullLength else { break }

            let searchRange = NSRange(location: searchStart, length: fullLength - searchStart)
            let found = fullText.range(of: trimmed, options: [], range: searchRange)
            guard found.location != NSNotFound else { continue }
            searchStart = found.location + found.length

            let rawText = fullText.substring(with: found)
            let exactText: String
            let origins: [Int]
            // `dropped` is small (a few pairs per page): the "does this line
            // contain any of them" check is cheap even when scanning the whole
            // set, far cheaper than rebuilding every line character by
            // character when (the common case) it is not needed.
            if dropped.contains(where: { $0 >= found.location && $0 < found.location + found.length }) {
                var cleanChars: [Character] = []
                var cleanOrigins: [Int] = []
                cleanChars.reserveCapacity(rawText.count)
                cleanOrigins.reserveCapacity(rawText.count)
                for (offset, ch) in rawText.enumerated() {
                    let orig = found.location + offset
                    guard !dropped.contains(orig) else { continue }
                    cleanChars.append(ch)
                    cleanOrigins.append(orig)
                }
                exactText = String(cleanChars)
                origins = cleanOrigins
            } else {
                exactText = rawText
                origins = Array(found.location ..< (found.location + found.length))
            }
            let rect = lineSelection.bounds(for: page)
            let (fontSize, isBold) = dominantFont(attributed: attributed, range: found)
            let superscripts = superscriptRanges(attributed: attributed, range: found, lineFontSize: fontSize)

            lines.append(ExtractedLine(
                text: exactText,
                charRange: CharRange(found),
                rect: rect,
                fontSize: fontSize,
                isBold: isBold,
                superscriptRanges: superscripts,
                charOrigins: origins
            ))
        }

        return (
            PageLayout(pageIndex: pageIndex, pageRect: pageRect, lines: lines, stringLength: fullLength),
            pageText
        )
    }

    private static func dominantFont(attributed: NSAttributedString?, range: NSRange) -> (CGFloat, Bool) {
        guard let attributed, range.length > 0, range.location >= 0,
              range.location + range.length <= attributed.length
        else { return (12, false) }

        var sizes: [CGFloat: Int] = [:]
        var boldChars = 0
        attributed.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            sizes[font.pointSize, default: 0] += subrange.length
            if font.fontDescriptor.symbolicTraits.contains(.bold) {
                boldChars += subrange.length
            }
        }
        let dominant = sizes.max(by: { $0.value < $1.value })?.key ?? 12
        return (dominant, boldChars * 2 > range.length)
    }

    /// Superscript digits (SPEC §7.2.4): a font noticeably smaller than the
    /// line's dominant body, and the stretch is made only of digits.
    private static func superscriptRanges(
        attributed: NSAttributedString?,
        range: NSRange,
        lineFontSize: CGFloat
    ) -> [CharRange] {
        guard let attributed, lineFontSize > 0, range.length > 0, range.location >= 0,
              range.location + range.length <= attributed.length
        else { return [] }

        var result: [CharRange] = []
        let fullString = attributed.string as NSString
        attributed.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            guard let font = value as? NSFont, font.pointSize > 0, font.pointSize < lineFontSize * 0.85 else { return }
            let substring = fullString.substring(with: subrange)
            guard !substring.isEmpty, substring.allSatisfy(\.isNumber) else { return }
            result.append(CharRange(subrange))
        }
        return result
    }
}
