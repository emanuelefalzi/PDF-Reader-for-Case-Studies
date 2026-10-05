import Foundation

/// Pure cleaning of the extracted text (SPEC §7.2), at the `IndexedText`
/// level so as to always keep the correspondence with the original character
/// indices. No PDFKit access: testable with synthetic lines.
enum TextCleaner {
    private static let ligatures: [Character: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl",
        "\u{FB03}": "ffi", "\u{FB04}": "ffl",
    ]

    /// Converts an `ExtractedLine` into `IndexedText`: ligatures expanded
    /// (SPEC §7.2.5) and superscript digits removed (SPEC §7.2.4), one
    /// character at a time so every clean character carries its original
    /// index.
    static func indexedText(for line: ExtractedLine) -> IndexedText {
        var result: IndexedText = []
        result.reserveCapacity(line.text.count)
        let base = line.charRange.location
        // `charOrigins`: when `LineExtractor` has removed a duplicate
        // character the map is no longer contiguous (`base + offset` would
        // skip the right index). `nil` only for a `layout.json` written before
        // this field or a synthetic line in the tests: there the map has
        // always been contiguous.
        let origins = line.charOrigins
        var superscriptIndices = Set<Int>()
        for range in line.superscriptRanges {
            superscriptIndices.formUnion(range.location ..< range.upperBound)
        }

        for (offset, ch) in line.text.enumerated() {
            let orig = origins?[offset] ?? (base + offset)
            if superscriptIndices.contains(orig) { continue }
            if let expansion = ligatures[ch] {
                for expandedChar in expansion { result.append(IndexedChar(ch: expandedChar, orig: orig)) }
            } else {
                result.append(IndexedChar(ch: ch, orig: orig))
            }
        }
        return result
    }

    /// Spaced letters recompacted (SPEC §7.2.2): sequences of **at least 3**
    /// space-separated tokens, each a single letter, are joined into one word
    /// by removing the spaces that separate them (the characters keep their
    /// original index). Real one-letter words ("a", "I") are not touched
    /// because, isolated, they do not form a sequence of 3+.
    static func recompactSpacedLetters(_ text: IndexedText) -> IndexedText {
        // Shortcut (memory, SPEC §9): the vast majority of lines have no
        // sequence to recompact, but the previous version still redid
        // `tokenize` (a full copy of the line in segments) plus `flatMap`
        // (another full copy) on EVERY line of the document, only to return
        // the same unchanged `text`. `hasSpacedLetterRun` is a single scan (no
        // allocation beyond scalar variables) that decides whether the heavy
        // reconstruction is really needed; on a document of hundreds of pages
        // this removes two character-by-character copies of the entire text
        // from the memory peak of `CleanPage.init` (measured).
        guard hasSpacedLetterRun(text) else { return text }

        var segments = tokenize(text)
        var i = 0
        while i < segments.count {
            guard case let .token(first) = segments[i], isSingleLetterToken(first) else {
                i += 1
                continue
            }
            var lastRunIndex = i
            var j = i
            while j + 2 < segments.count,
                  case .space = segments[j + 1],
                  case let .token(next) = segments[j + 2], isSingleLetterToken(next)
            {
                lastRunIndex = j + 2
                j += 2
            }
            let runLength = (lastRunIndex - i) / 2 + 1
            if runLength >= 3 {
                var merged: IndexedText = []
                var k = i
                while k <= lastRunIndex {
                    if case let .token(t) = segments[k] { merged.append(contentsOf: t) }
                    k += 2
                }
                segments.replaceSubrange(i ... lastRunIndex, with: [.token(merged)])
                i += 1
            } else {
                i += 1
            }
        }
        return segments.flatMap { segment -> IndexedText in
            switch segment {
            case let .token(t), let .space(t): return t
            }
        }
    }

    /// True if `text` contains at least 3 consecutive one-letter tokens
    /// separated by spaces (the same trigger condition as the "recompact"
    /// branch below, but never copying the characters: only indices and
    /// scalar counts).
    private static func hasSpacedLetterRun(_ text: IndexedText) -> Bool {
        var i = 0
        let n = text.count
        var run = 0
        while i < n {
            while i < n, text[i].ch.isWhitespace { i += 1 }
            guard i < n else { break }
            let start = i
            while i < n, !text[i].ch.isWhitespace { i += 1 }
            if i - start == 1, text[start].ch.isLetter {
                run += 1
                if run >= 3 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    private enum Segment {
        case token(IndexedText)
        case space(IndexedText)
    }

    private static func tokenize(_ text: IndexedText) -> [Segment] {
        var result: [Segment] = []
        var i = 0
        while i < text.count {
            let isSpace = text[i].ch.isWhitespace
            var j = i
            while j < text.count, text[j].ch.isWhitespace == isSpace { j += 1 }
            let slice = Array(text[i ..< j])
            result.append(isSpace ? .space(slice) : .token(slice))
            i = j
        }
        return result
    }

    private static func isSingleLetterToken(_ token: IndexedText) -> Bool {
        token.count == 1 && token[0].ch.isLetter
    }
}
