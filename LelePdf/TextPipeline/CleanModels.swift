import Foundation

/// A character of the clean text with the index of the original character
/// in `page.string` it comes from (SPEC §7.2: "the correspondence between
/// clean text and original character indices is always kept"). Spaces or
/// separators added during cleaning point to the nearest original
/// character, as the index map requires (SPEC §7.3 last point).
struct IndexedChar: Sendable, Equatable {
    let ch: Character
    let orig: Int
}

typealias IndexedText = [IndexedChar]

extension Array where Element == IndexedChar {
    var string: String { String(map(\.ch)) }
}

/// A line after ligatures/spaced letters/superscript digits (SPEC §7.2.2,
/// §7.2.4, §7.2.5). Headers/footers stay as lines with
/// `removedAsHeaderFooter = true` (for the debug overlay, SPEC §11) but are
/// excluded from the clean text through `CleanPage.contentLines`. A word
/// split at the end of a line makes the next line merge into this one
/// (`joinedWithNext`), which then becomes `consumedByPrevious` and is
/// excluded from `contentLines`.
struct CleanLine: Sendable, Equatable {
    let pageIndex: Int
    /// Index of the line in the original page (SPEC §7.1 working order):
    /// stable even if `contentLines` filters out some lines, it lets the
    /// debug overlay find the exact line again.
    let lineIndex: Int
    var text: IndexedText
    let rect: PageRect
    let fontSize: CGFloat
    let isBold: Bool
    var removedAsHeaderFooter = false
    var joinedWithNext = false
    var consumedByPrevious = false
}

/// All the `CleanLine`s of a page, with the page's dimensions (needed by
/// `HeaderFooterRemover` for the top/bottom 8%, SPEC §7.2.1).
struct CleanPage: Sendable {
    let pageIndex: Int
    let pageRect: PageRect
    var lines: [CleanLine]

    /// Lines that are actually body text: not headers/footers, not absorbed
    /// by a merge across a split line end.
    var contentLines: [CleanLine] {
        lines.filter { !$0.removedAsHeaderFooter && !$0.consumedByPrevious }
    }

    /// Builds the raw `CleanLine`s from a `PageLayout` (SPEC §7.2.5
    /// ligatures, §7.2.4 superscript digits, §7.2.2 spaced letters). Header
    /// removal and the merging of split words come later, in the pipeline
    /// (they depend on all the pages or on the next line).
    init(layout: PageLayout) {
        pageIndex = layout.pageIndex
        pageRect = layout.pageRect
        lines = layout.lines.enumerated().map { index, line in
            let cleaned = TextCleaner.recompactSpacedLetters(TextCleaner.indexedText(for: line))
            return CleanLine(
                pageIndex: layout.pageIndex,
                lineIndex: index,
                text: cleaned,
                rect: line.rect,
                fontSize: line.fontSize,
                isBold: line.isBold
            )
        }
    }

    init(pageIndex: Int, pageRect: PageRect, lines: [CleanLine]) {
        self.pageIndex = pageIndex
        self.pageRect = pageRect
        self.lines = lines
    }
}
