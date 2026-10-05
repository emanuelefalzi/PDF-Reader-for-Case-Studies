import Foundation

/// Repetitions (SPEC §7.5.4, §5.4 "Repetition"): computed at load time (or on
/// every analysis change), never saved. For each term with at least one real
/// mark, the later occurrences of the same text in the other analyzed blocks
/// (in document order, after the block of the first real mark), excluding the
/// portions already covered by a real mark in that block. Pure and fast (no
/// actor/PDFKit here): called on every analysis change (SPEC "not per
/// frame"), not on every scroll frame. It is no longer redone from scratch,
/// though: `RepetitionsIncremental.swift` (same type, separate file to keep
/// files small) adds `IncrementalState`/`computeFull`/`update`, and
/// `RepetitionsEngine.swift` runs them off the MainActor. This file remains
/// the sole definition of the algorithm (`compute`, a thin wrapper over
/// `computeFull`) and of the shared utilities (`Haystack`,
/// `wordBoundaryOccurrences`, `intersects`).
enum Repetitions {
    struct Occurrence: Sendable, Equatable {
        var blockId: String
        var termId: String
        /// In `Character` units of `TextBlock.cleanText` (the same unit as
        /// `MarkRange`).
        var range: NSRange
    }

    /// Full recomputation (used by `RepetitionsTests`, `MapGraphSource` and as
    /// the base/fallback of `RepetitionsIncremental.swift`): the same
    /// semantics as ever, just implemented on top of `computeFull` so as not
    /// to keep two copies of the same algorithm.
    static func compute(blocks: [TextBlock], analysis: AnalysisRecord) -> [Occurrence] {
        computeFull(blocks: blocks, analysis: analysis).occurrences
    }

    /// Not `private` (`RepetitionsIncremental.swift` holds the same type in a
    /// separate file to keep files small): reused by the incremental
    /// computation.
    static func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        NSIntersectionRange(a, b).length > 0
    }

    /// Case-insensitive, word-boundary occurrences, in `Character` units of
    /// `cleanText` (not `NSRegularExpression`/UTF-16: the same unit as the
    /// module's other coordinates).
    static func wordBoundaryOccurrences(of text: String, in cleanText: String) -> [NSRange] {
        wordBoundaryOccurrences(of: text, in: Haystack(cleanText))
    }

    /// A block's text, ready for comparison: the original and the lowercased
    /// version as `[Character]`, computed once per block. Explicitly
    /// `Sendable`: `IncrementalState.haystackByBlock` keeps it between calls
    /// to `RepetitionsEngine`, off the MainActor.
    struct Haystack: Sendable {
        let characters: [Character]
        let lowercased: [Character]

        init(_ text: String) {
            characters = Array(text)
            lowercased = characters.map { Character($0.lowercased()) }
        }
    }

    static func wordBoundaryOccurrences(of text: String, in haystackText: Haystack) -> [NSRange] {
        let needle = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard !needle.isEmpty else { return [] }
        let haystack = haystackText.characters
        let haystackLower = haystackText.lowercased

        var results: [NSRange] = []
        var i = 0
        while i + needle.count <= haystackLower.count {
            if haystackLower[i ..< (i + needle.count)].elementsEqual(needle) {
                let leftOK = i == 0 || !isWordChar(haystack[i - 1])
                let rightIndex = i + needle.count
                let rightOK = rightIndex == haystack.count || !isWordChar(haystack[rightIndex])
                if leftOK, rightOK {
                    results.append(NSRange(location: i, length: needle.count))
                    i += needle.count
                    continue
                }
            }
            i += 1
        }
        return results
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}
