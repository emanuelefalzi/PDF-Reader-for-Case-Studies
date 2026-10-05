import Foundation

/// The stretch of a block on a single page (SPEC §7.3 last point):
/// `cleanStart`/`cleanLength` are character offsets (`Character`, not UTF-16)
/// inside `TextBlock.cleanText`; `charMap[i]` is the index of the original
/// character in that page's `page.string` corresponding to the clean
/// character `cleanStart + i`.
struct BlockPageSpan: Sendable, Equatable, Codable {
    let page: Int
    let cleanStart: Int
    let cleanLength: Int
    let charMap: [Int]
}

/// An analysis block (SPEC §7.3, §8). `lineRectsByPage` is not in the
/// `documento.json` schema (SPEC §8 does not list it): it serves only the
/// debug overlay and the margin bar (SPEC §5.4, §11), and since the pipeline
/// can recompute it, it is not needed in the Store.
struct TextBlock: Sendable, Equatable, Codable, Identifiable {
    let id: String
    let sectionPath: [String]
    let pageStart: Int
    let pageEnd: Int
    let cleanText: String
    let textHash: String
    let words: Int
    let spans: [BlockPageSpan]
    let lineRectsByPage: [Int: [PageRect]]
    /// When the section (§7.3, from a heading to the next one of equal or
    /// higher level, taking the lowest-level heading) exceeds the length
    /// limit, it is split into numbered parts ("3.2 · part 2 of 3",
    /// `BlockLabeling`). `nil` for a block that is already the whole section
    /// (the normal case). Optional: a `documento.json` written before this
    /// change decodes both as `nil`, so data already saved stays readable
    /// with no need for migration.
    var partIndex: Int? = nil
    var partCount: Int? = nil

    /// Resolves a range of the block's clean text into one or more
    /// (page, range of the page's original characters) pairs, SPEC §7.3 last
    /// point. `cleanRange` is in characters (`Character`) of `cleanText`, the
    /// same unit as `cleanStart`/`cleanLength`.
    func resolve(cleanRange: NSRange) -> [(page: Int, range: NSRange)] {
        let lower = cleanRange.location
        let upper = cleanRange.location + cleanRange.length
        var result: [(page: Int, range: NSRange)] = []

        for span in spans {
            let spanLower = span.cleanStart
            let spanUpper = span.cleanStart + span.cleanLength
            let overlapLower = max(lower, spanLower)
            let overlapUpper = min(upper, spanUpper)
            guard overlapLower < overlapUpper, !span.charMap.isEmpty else { continue }

            let localIndices = (overlapLower - spanLower) ..< (overlapUpper - spanLower)
            let origIndices = localIndices.compactMap { span.charMap.indices.contains($0) ? span.charMap[$0] : nil }
            guard let minOrig = origIndices.min(), let maxOrig = origIndices.max() else { continue }
            result.append((span.page, NSRange(location: minOrig, length: maxOrig - minOrig + 1)))
        }
        return result
    }

    /// Inverse of `resolve(cleanRange:)`: from a range of **original**
    /// characters (`page.string`) on a page touched by this block, to the
    /// corresponding range in the clean text (`cleanText`). `nil` if the
    /// block does not touch the page or the range does not overlap any mapped
    /// character of the span (for example it falls entirely on a header that
    /// was already removed).
    func inverseResolve(page pageIndex: Int, origRange: NSRange) -> NSRange? {
        guard let span = spans.first(where: { $0.page == pageIndex }), !span.charMap.isEmpty else { return nil }
        let lower = origRange.location
        let upper = origRange.location + origRange.length
        var minLocal: Int?
        var maxLocal: Int?
        for local in span.charMap.indices {
            let orig = span.charMap[local]
            guard orig >= lower, orig < upper else { continue }
            minLocal = min(minLocal ?? local, local)
            maxLocal = max(maxLocal ?? local, local)
        }
        guard let minLocal, let maxLocal else { return nil }
        return NSRange(location: span.cleanStart + minLocal, length: maxLocal - minLocal + 1)
    }
}
