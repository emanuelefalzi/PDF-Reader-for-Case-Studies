import Foundation

/// Matches a mark's text against the block's clean text (SPEC §7.5
/// post-processing point 2): exact search, then case-insensitive, then
/// tolerant, always starting from the occurrence after the one already
/// matched for the same text (the caller keeps that position, see
/// `AnalysisPostProcessor`). Works on `[Character]` (not `NSString`/UTF-16) to
/// stay in the same unit as `TextBlock.cleanText`/`MarkRange`.
enum MarkMatcher {
    enum Strategy: Sendable, Equatable { case exact, caseInsensitive, tolerant }

    struct MatchResult: Sendable, Equatable {
        var range: NSRange
        var strategy: Strategy
    }

    /// Maximum Levenshtein distance for considering two tokens "equivalent"
    /// (SPEC: "tolerance: Levenshtein distance ≤ 2 on equivalent tokens"). The
    /// chosen interpretation is that each token of the mark must have a
    /// matching token in the candidate window at distance ≤ 2 (not the sum
    /// over the whole phrase), so a single typo per word stays tolerated
    /// without the threshold collapsing on long phrases.
    static let tolerantTokenDistance = 2

    static func match(text: String, in cleanTextChars: [Character], after start: Int) -> MatchResult? {
        if let range = findExact(text, in: cleanTextChars, caseInsensitive: false, after: start) {
            return MatchResult(range: range, strategy: .exact)
        }
        if let range = findExact(text, in: cleanTextChars, caseInsensitive: true, after: start) {
            return MatchResult(range: range, strategy: .caseInsensitive)
        }
        if let range = findTolerant(text, in: cleanTextChars, after: start) {
            return MatchResult(range: range, strategy: .tolerant)
        }
        return nil
    }

    // MARK: - Exact / case-insensitive

    private static func findExact(_ needle: String, in haystack: [Character], caseInsensitive: Bool, after start: Int) -> NSRange? {
        let needleChars = Array(caseInsensitive ? needle.lowercased() : needle)
        guard !needleChars.isEmpty, needleChars.count <= haystack.count else { return nil }
        let hay = caseInsensitive ? haystack.map { Character($0.lowercased()) } : haystack

        var i = max(start, 0)
        while i + needleChars.count <= hay.count {
            if Array(hay[i ..< (i + needleChars.count)]) == needleChars {
                return NSRange(location: i, length: needleChars.count)
            }
            i += 1
        }
        return nil
    }

    // MARK: - Tollerante (token-wise Levenshtein)

    private static func findTolerant(_ needle: String, in haystack: [Character], after start: Int) -> NSRange? {
        let needleTokens = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !needleTokens.isEmpty else { return nil }
        let haystackTokens = tokenize(haystack)
        guard haystackTokens.count >= needleTokens.count else { return nil }

        for windowStart in 0 ... (haystackTokens.count - needleTokens.count) {
            let firstTokenRange = haystackTokens[windowStart].range
            guard firstTokenRange.location >= start else { continue }
            var allEquivalent = true
            for offset in 0 ..< needleTokens.count {
                let candidate = haystackTokens[windowStart + offset].token
                if levenshtein(needleTokens[offset].lowercased(), candidate.lowercased()) > tolerantTokenDistance {
                    allEquivalent = false
                    break
                }
            }
            guard allEquivalent else { continue }
            let lastTokenRange = haystackTokens[windowStart + needleTokens.count - 1].range
            let length = (lastTokenRange.location + lastTokenRange.length) - firstTokenRange.location
            return NSRange(location: firstTokenRange.location, length: length)
        }
        return nil
    }

    /// Whitespace-separated tokens, each with its range (in `Character` units
    /// of `haystack`).
    private static func tokenize(_ text: [Character]) -> [(token: String, range: NSRange)] {
        var result: [(String, NSRange)] = []
        var i = 0
        while i < text.count {
            if text[i].isWhitespace { i += 1; continue }
            var j = i
            while j < text.count, !text[j].isWhitespace { j += 1 }
            result.append((String(text[i ..< j]), NSRange(location: i, length: j - i)))
            i = j
        }
        return result
    }

    /// Classic Levenshtein distance (dynamic programming, two rows).
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0 ... b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            current[0] = i
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}
