import Foundation
@preconcurrency import PDFKit

/// Removes characters duplicated by simulated bold/an extraction defect
/// ("Buuildingg the Teeam" instead of "Building the Team", a real case: the
/// cover of the Ockham Technologies (A): Building the Team case).
///
/// **Confirmed cause** (`characterBounds(at:)` on the real PDF, not just a
/// hypothesis): it is not a pure vector overprint; `page.string` sometimes
/// repeats an already read character as a separate "mini token", with a
/// spurious space inserted in between by PDFKit, at an almost null distance
/// (a fraction of the character width) instead of at the normal distance
/// between two different words. It happens both in the title (large font,
/// bounding boxes almost overlapping) and in the body text (smaller font,
/// a small but measurable offset): the same defect, only the threshold
/// differs because the absolute geometry changes with the font size, hence a
/// threshold relative to the character width, not a fixed value in points.
///
/// **What distinguishes a true double letter ("Teeth", "book") from this
/// defect is not the repetition of the letter, it is the geometry**: two real
/// doubled letters in the same word are always "attached" in `page.string`
/// (no space between the two, a horizontal offset of ~0, measured on
/// "will"/"nd" of the real PDF). A duplicate caused by the defect ALWAYS has
/// a space (a single character) between the two occurrences. Requiring that
/// space as a precondition (besides the offset threshold) avoids touching
/// real doubled letters, which never have that space.
@MainActor
enum DuplicateGlyphCleaner {
    /// Indices of `text` (the spurious space, plus one of the two occurrences
    /// of the repeated character) to remove when building a line's clean
    /// text. A single pass over the whole page (not per line: two almost
    /// overlapping occurrences still stay on the same visual line, which the
    /// vertical proximity check below guarantees on its own, with no need to
    /// work per `PDFSelection` line).
    static func duplicateIndices(page: PDFPage, text: NSString) -> Set<Int> {
        let length = text.length
        guard length > 1 else { return [] }

        // Space-separated tokens (a Unicode whitespace character): each token
        // is a range [location, location+length) of consecutive non-space
        // indices.
        var tokens: [NSRange] = []
        var i = 0
        while i < length {
            if isSpaceChar(text, i) { i += 1; continue }
            let start = i
            while i < length, !isSpaceChar(text, i) { i += 1 }
            tokens.append(NSRange(location: start, length: i - start))
        }
        guard tokens.count > 1 else { return [] }

        // A spaced-letters header ("N O A M W A S S E R M A N") has a single
        // space between EVERY letter, including the two of a real double
        // letter ("WASSERMAN"): there the space is not a signal of the defect,
        // it is the style; `recompactSpacedLetters` later in the pipeline
        // (SPEC §7.2.2) recompacts it anyway. The same condition that function
        // uses to recognize it (3+ consecutive tokens of a single LETTER, not
        // a digit: "1 0 0" in the date remains a candidate, only letters have
        // a deliberately spaced style): the tokens that are part of it are
        // never candidates for the defect, which instead always pairs a short
        // token with a fragment of several characters.
        let spacedRunTokens = spacedLetterRunTokenIndices(tokens, in: text)

        var drop = Set<Int>()
        var t = 0
        while t < tokens.count - 1 {
            let left = tokens[t]
            let right = tokens[t + 1]
            guard left.length > 0, right.length > 0 else { t += 1; continue }
            guard !spacedRunTokens.contains(t), !spacedRunTokens.contains(t + 1) else { t += 1; continue }

            // Exactly ONE real whitespace character (SPACE, not a "line
            // break") between the two tokens. A "\n" between two tokens that
            // share, purely by chance, the last/first letter ("kept" /
            // "thinking", found in the real PDF during development: PDFKit
            // inserts a "\n" there while staying on the same Y) is NOT our
            // defect: it is a real line end, even though the vertical proximity
            // check below alone would not be enough to exclude it (the Y stays
            // almost identical). The real defect measured on the real PDF
            // always has a space, never a line break, between the two
            // occurrences.
            let gapStart = left.location + left.length
            let gapLength = right.location - gapStart
            guard gapLength == 1, isPlainSpace(text, gapStart) else { t += 1; continue }

            let leftLastIndex = left.location + left.length - 1
            let rightFirstIndex = right.location
            let leftChar = text.character(at: leftLastIndex)
            let rightChar = text.character(at: rightFirstIndex)
            guard leftChar == rightChar, isLetterOrDigit(leftChar) else { t += 1; continue }

            let leftBounds = page.characterBounds(at: leftLastIndex)
            let rightBounds = page.characterBounds(at: rightFirstIndex)
            guard leftBounds.width > 0 || rightBounds.width > 0 else { t += 1; continue }

            // Same visual line: a small vertical difference relative to the
            // height of the two characters (by construction this excludes a
            // title that wraps exactly on a repeated letter, the "Te" / "eam"
            // case observed on the real PDF: a genuine line break, not our
            // defect, stays untouched).
            let refHeight = max(leftBounds.height, rightBounds.height, 1)
            guard abs(leftBounds.midY - rightBounds.midY) < refHeight else { t += 1; continue }

            // Horizontal offset within a fraction of the character width: a
            // real repeated word with a real space between the two (e.g.
            // "the the") has an offset the size of a real word space, much
            // larger.
            let refWidth = max(leftBounds.width, rightBounds.width, 1)
            let gap = rightBounds.minX - leftBounds.maxX
            guard gap < refWidth * 1.5 else { t += 1; continue }

            // The left occurrence is always kept and the first letter of the
            // right token is removed (plus the spurious space): for a
            // one-letter ghost token, before the real word ("T" "Technologies")
            // or after it ("Puerto" "o"), this alone is enough to rebuild the
            // right text, because when `right` has length 1 its "first letter"
            // is also its only one: removing it empties the whole ghost
            // token.
            drop.insert(gapStart)
            drop.insert(rightFirstIndex)

            if right.length == 1 {
                // The right token was an isolated ghost, just removed in its
                // entirety: it must NOT be re-evaluated as the "left" of the next
                // pair ("Atlanta" "a" "after", seen on the real PDF: the ghost
                // "a" matches BOTH neighbors by construction, otherwise the first
                // letter of "after" would be removed too). Skip past it.
                t += 2
            } else {
                t += 1
            }
        }
        return drop
    }

    /// Indices (in `tokens`) of the tokens that are part of a sequence of at
    /// least 3 consecutive one-letter tokens separated by spaces (the same
    /// rule as `TextCleaner.hasSpacedLetterRun`, duplicated here instead of
    /// shared: that one works on an already built `IndexedText`, this one on
    /// the raw `NSString` before building it).
    private static func spacedLetterRunTokenIndices(_ tokens: [NSRange], in text: NSString) -> Set<Int> {
        var result = Set<Int>()
        var runStart: Int?
        for (index, token) in tokens.enumerated() {
            let isSingleLetter = token.length == 1 && isLetter(text.character(at: token.location))
            if isSingleLetter {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                if index - start >= 3 { result.formUnion(start ..< index) }
                runStart = nil
            }
        }
        if let start = runStart, tokens.count - start >= 3 {
            result.formUnion(start ..< tokens.count)
        }
        return result
    }

    private static func isLetter(_ utf16: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(utf16) else { return false }
        return CharacterSet.letters.contains(scalar)
    }

    private static func isSpaceChar(_ text: NSString, _ index: Int) -> Bool {
        guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// True only for a real horizontal spacing character (space, tab):
    /// it excludes "\n"/"\r"; a line break, even when the Y does not change
    /// (real PDF), is never our defect.
    private static func isPlainSpace(_ text: NSString, _ index: Int) -> Bool {
        guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }

    private static func isLetterOrDigit(_ utf16: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(utf16) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
