import Foundation

/// Joining of words split at the end of a line (SPEC §7.2.3): `word-⏎word`
/// becomes `wordword` when the next line (body text, not a header) starts in
/// lowercase. Pure: it works after the removal of headers/footers, so it
/// never joins across them.
enum HyphenationJoiner {
    static func apply(to pages: [CleanPage]) -> [CleanPage] {
        pages.map(joinPage)
    }

    private static func joinPage(_ page: CleanPage) -> CleanPage {
        var lines = page.lines
        var i = 0
        while i < lines.count {
            guard !lines[i].removedAsHeaderFooter, !lines[i].consumedByPrevious else {
                i += 1
                continue
            }
            guard let j = nextContentLineIndex(after: i, in: lines) else { break }

            guard let lastChar = lines[i].text.last?.ch, isHyphen(lastChar) else {
                i = j
                continue
            }
            guard let firstChar = firstNonWhitespace(lines[j].text), firstChar.isLowercase else {
                i = j
                continue
            }

            var merged = lines[i].text
            merged.removeLast()
            merged.append(contentsOf: lines[j].text)
            lines[i].text = merged
            lines[i].joinedWithNext = true
            lines[j].consumedByPrevious = true
            i = j + 1
        }
        return CleanPage(pageIndex: page.pageIndex, pageRect: page.pageRect, lines: lines)
    }

    private static func nextContentLineIndex(after index: Int, in lines: [CleanLine]) -> Int? {
        var j = index + 1
        while j < lines.count {
            if !lines[j].removedAsHeaderFooter, !lines[j].consumedByPrevious { return j }
            j += 1
        }
        return nil
    }

    private static func isHyphen(_ ch: Character) -> Bool {
        ch == "-" || ch == "\u{2010}" || ch == "\u{2011}"
    }

    private static func firstNonWhitespace(_ text: IndexedText) -> Character? {
        text.first { !$0.ch.isWhitespace }?.ch
    }
}
