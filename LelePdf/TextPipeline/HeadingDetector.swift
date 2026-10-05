import Foundation

/// Headings (SPEC §7.3): font ≥1.15× the body text, or a short bold line
/// (fewer than 12 words) followed by normal text, or numbering ("4.1",
/// "Chapter 2"). Body text = the most frequent size by character count,
/// across the whole document.
enum HeadingDetector {
    static let sizeRatio: CGFloat = 1.15

    static func bodyFontSize(_ pages: [CleanPage]) -> CGFloat {
        var charsBySize: [CGFloat: Int] = [:]
        for page in pages {
            for line in page.contentLines {
                charsBySize[rounded(line.fontSize), default: 0] += line.text.count
            }
        }
        return charsBySize.max(by: { $0.value < $1.value })?.key ?? 12
    }

    /// `excludedLines` are the lines already excluded from the flow
    /// (Exhibit/table/figure zones, `ExhibitDetector`): a caption such as
    /// "Exhibit 1" (Merck, Palatino-Bold 9.96, the same size as the body
    /// but bold and short) would otherwise satisfy the "short bold line" rule
    /// and become a bogus heading (M2/M4 fix).
    static func detect(pages: [CleanPage], bodyFontSize: CGFloat, excludedLines: [Int: Set<Int>] = [:]) -> [Heading] {
        let indexPages = printedIndexPages(pages)

        // Ranking of levels (SPEC §7.3 "the level is derived from the size
        // ranking"): only the sizes that recur on at least 2 different pages.
        // The document title (cover page, e.g. Merck Palatino-Bold 18.96)
        // almost always appears just once, on a single page: if it took part
        // in the ranking it would alone consume level 1 and push the real
        // sections (Merck: Palatino-Bold 12.96) to level 2, the real level-2
        // ones (Palatino-Italic 12.0) to 3, etc.; the bug observed on the
        // Merck case (a generated contents with a single entry, the title).
        // Excluding it from the ranking still does not prevent it from being
        // detected as a heading if its size is also a recurring size
        // elsewhere; if it is not, it simply generates no `Heading` (not
        // needed: `documento.json.title` already comes from
        // `DocumentTitle.resolve` on the PDF's metadata).
        var pagesBySize: [CGFloat: Set<Int>] = [:]
        for page in pages where !indexPages.contains(page.pageIndex) {
            let excluded = excludedLines[page.pageIndex] ?? []
            for line in page.contentLines where !excluded.contains(line.lineIndex) {
                let size = rounded(line.fontSize)
                guard size >= bodyFontSize * sizeRatio else { continue }
                pagesBySize[size, default: []].insert(page.pageIndex)
            }
        }
        let rankedSizes = pagesBySize.filter { $0.value.count >= 2 }.keys.sorted(by: >)

        var headings: [Heading] = []
        for page in pages where !indexPages.contains(page.pageIndex) {
            let excluded = excludedLines[page.pageIndex] ?? []
            let lines = page.contentLines
            for (index, line) in lines.enumerated() {
                guard !excluded.contains(line.lineIndex) else { continue }
                let text = line.text.string.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let size = rounded(line.fontSize)
                let wordCount = text.split(whereSeparator: \.isWhitespace).count

                let level: Int
                if size >= bodyFontSize * sizeRatio {
                    // Large size but not recurring elsewhere (a cover-page
                    // title, see above): it is not a section, skip it.
                    guard let levelIndex = rankedSizes.firstIndex(of: size) else { continue }
                    level = min(3, levelIndex + 1)
                } else if line.isBold, wordCount < 12, text.contains(where: \.isLetter), index + 1 < lines.count {
                    level = 2
                } else if isNumberedHeading(text) {
                    level = numberedHeadingLevel(text)
                } else {
                    continue
                }
                headings.append(Heading(pageIndex: page.pageIndex, lineIndex: line.lineIndex, text: text, level: level, rect: line.rect))
            }
        }
        return headings
    }

    private static func rounded(_ size: CGFloat) -> CGFloat { (size * 2).rounded() / 2 }

    private static func isNumberedHeading(_ text: String) -> Bool {
        text.range(
            of: "^(chapter|section)\\s+[0-9]+\\b|^[0-9]+(\\.[0-9]+)+\\s+\\S",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func numberedHeadingLevel(_ text: String) -> Int {
        if text.range(of: "^chapter\\s+[0-9]+", options: [.regularExpression, .caseInsensitive]) != nil { return 1 }
        let dotCount = text.prefix(while: { $0.isNumber || $0 == "." }).filter { $0 == "." }.count
        return min(3, dotCount + 1)
    }

    /// Pages of a contents/summary printed **in the PDF itself** (Draghi
    /// p. 12 "Contents"): lines with dot leaders ("title . . . . 11") that
    /// share the font size of real headings elsewhere in the document. If at
    /// least 2 lines of the page have that pattern, the whole page is treated
    /// as a printed contents and none of its lines becomes a `Heading`;
    /// otherwise the generated contents would duplicate every chapter (one
    /// entry from the summary page, one from the real one).
    private static func printedIndexPages(_ pages: [CleanPage]) -> Set<Int> {
        var result = Set<Int>()
        for page in pages {
            let dotLeaderLines = page.contentLines.filter { looksLikeIndexLine($0.text.string) }.count
            if dotLeaderLines >= 2 { result.insert(page.pageIndex) }
        }
        return result
    }

    private static func looksLikeIndexLine(_ text: String) -> Bool {
        text.range(of: "\\.(\\s?\\.){3,}", options: .regularExpression) != nil
    }
}
