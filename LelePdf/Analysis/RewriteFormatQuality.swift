import Foundation

/// Automatic checks on the FORMAT of an already saved rewrite (`RewriteItem`,
/// the same shape written in `analisi.json`), following the project's quality
/// criteria for the summary (the most important part). They do not call
/// Claude, and need no original PDF beyond what the caller already passes (the
/// block's paragraph count). Pure: no dependency on
/// `AnalysisController`/MainActor, reusable both by tests and, in the future,
/// by a check inside the app itself (SPEC quality: "automatic check on real
/// analyses").
enum RewriteFormatQuality {
    /// Word count of a string (consecutive spaces count once), the same
    /// definition already used elsewhere for `words`/`rewriteWords`
    /// (`RealBlockAnalysisTests`, `BlockSegmenter`).
    static func wordCount(_ text: String?) -> Int {
        (text ?? "").split { $0.isWhitespace }.count
    }

    /// Total words of the rewrite (all elements, points AND subpoints
    /// included); SPEC §7.5 "total length of the rewrite". Lines of
    /// `kind == .outline` (`RewriteOutlineReader`, which also reads an old
    /// `kind == .bullets` with the same convention used by the panel/export)
    /// count the same as `items`/`subItems` do for every other `kind`, so the
    /// total stays correct both for a current analysis and for one saved
    /// earlier.
    static func totalWords(_ rewrite: [RewriteItem]) -> Int {
        rewrite.reduce(0) { total, item in
            switch item.kind {
            case .outline, .bullets:
                return total + RewriteOutlineReader.lines(for: item).reduce(0) { $0 + wordCount($1.text) }
            default:
                return total + wordCount(item.text)
                    + (item.items ?? []).reduce(0) { $0 + wordCount($1) }
                    + (item.subItems ?? []).reduce(0) { $0 + $1.reduce(0) { $0 + wordCount($1) } }
                    + (item.columns ?? []).reduce(0) { $0 + wordCount($1) }
                    + (item.rows ?? []).reduce(0) { $0 + $1.reduce(0) { $0 + wordCount($1) } }
            }
        }
    }

    /// Line types that count as a "bullet" for the criterion "at least 80% of
    /// the content is in bullets" (point/subpoint/explanation/consequence; not
    /// note/formula/subheading/definition/example, which are deliberately a
    /// DIFFERENT line type from a bullet, even though they remain legitimate
    /// rewrite content).
    private static func isBulletLikeLine(_ type: RewriteLineType) -> Bool {
        switch type {
        case .point, .subpoint, .explanation, .consequence: true
        case .note, .formula, .subheading, .definition, .example, .other: false
        }
    }

    /// Words inside point/subpoint/explanation/consequence lines or, for an
    /// analysis saved before the outline format, inside a `bullets` element
    /// (main points + subpoints): the criterion "at least 80% of the content
    /// is in bullets".
    static func bulletsWords(_ rewrite: [RewriteItem]) -> Int {
        rewrite.filter { $0.kind == .bullets || $0.kind == .outline }.reduce(0) { total, item in
            total + RewriteOutlineReader.lines(for: item)
                .filter { isBulletLikeLine($0.type) }
                .reduce(0) { $0 + wordCount($1.text) }
        }
    }

    /// Percentage (0-100) of the rewrite's content that is in bullets. `100`
    /// by convention if the rewrite is empty (no content to penalize).
    static func bulletsSharePercent(_ rewrite: [RewriteItem]) -> Int {
        let total = totalWords(rewrite)
        guard total > 0 else { return 100 }
        return Int((Double(bulletsWords(rewrite)) / Double(total) * 100).rounded())
    }

    /// Number of main points (point or consequence; normally one per paragraph
    /// of the source block, `analysis.md` rule 4) across the whole rewrite:
    /// level-0 lines of a `kind == .outline`, or `items` of an old
    /// `kind == .bullets` (summed even if there is more than one
    /// `bullets`/`outline` element, so the check does not fail on an analysis
    /// with several blocks of the same kind).
    static func mainBulletCount(_ rewrite: [RewriteItem]) -> Int {
        rewrite.filter { $0.kind == .bullets || $0.kind == .outline }.reduce(0) { total, item in
            total + RewriteOutlineReader.lines(for: item).filter { $0.type == .point || $0.type == .consequence }.count
        }
    }

    /// Maximum depth reached by the rewrite: `2` if at least one
    /// subpoint/explanation line or a non-empty old `bullets` subpoint exists,
    /// otherwise `1`.
    static func maxDepth(_ rewrite: [RewriteItem]) -> Int {
        let hasNestedLines = rewrite.contains { item in
            guard item.kind == .bullets || item.kind == .outline else { return false }
            return RewriteOutlineReader.lines(for: item).contains { $0.type.isNested }
        }
        return hasNestedLines ? 2 : 1
    }

    /// Criterion "every paragraph of the original text has at least one
    /// matching point": compares the number of main points with
    /// `paragraphCount` (the caller derives it from `TextBlock.cleanText`,
    /// with "\n\n" as the paragraph separator, `BlockSegmenter.makeBlock`).
    /// Tolerance of 1 fewer (analysis.md rule 4: "a paragraph made only of a
    /// citation/heading fragment ... is the only exception").
    static func coversEveryParagraph(mainBulletCount: Int, paragraphCount: Int) -> Bool {
        mainBulletCount >= max(0, paragraphCount - 1)
    }

    /// Criterion "one idea per bullet": a point (main or subpoint) above this
    /// word threshold is almost certainly more than one idea joined with
    /// "and"/commas instead of being split. The same threshold (~20 words)
    /// is already imposed by the prompt (`analysis.md`).
    static let maxWordsPerBullet = 24

    /// Points (main or subpoints) of a `bullets` over `maxWordsPerBullet`,
    /// with the index of the main point they belong to (useful for a readable
    /// log in tests/verification).
    static func overlongBullets(_ rewrite: [RewriteItem]) -> [(mainIndex: Int, text: String, words: Int)] {
        var result: [(Int, String, Int)] = []
        for item in rewrite where item.kind == .bullets || item.kind == .outline {
            var mainIndex = -1
            for line in RewriteOutlineReader.lines(for: item) where isBulletLikeLine(line.type) {
                if !line.type.isNested { mainIndex += 1 }
                let count = wordCount(line.text)
                if count > maxWordsPerBullet { result.append((max(mainIndex, 0), line.text, count)) }
            }
        }
        return result
    }

    /// Summary of all the "mandatory" quality criteria that can be verified
    /// without the original PDF (the format criteria; paragraph coverage if
    /// `paragraphCount` is provided). The "block = section" criterion is
    /// verified elsewhere (`BlockSegmentationTests`, on block construction, not
    /// on the rewrite); order, hierarchy and nothing-invented remain a
    /// spot-check read (SPEC), not automatable here.
    struct Report: Equatable {
        var bulletsSharePercent: Int
        var mainBulletCount: Int
        var maxDepth: Int
        var overlongBulletCount: Int
        var meetsBulletsShareGoal: Bool // >= 80%
        var meetsParagraphCoverage: Bool? // nil if paragraphCount is not provided
    }

    static func evaluate(_ rewrite: [RewriteItem], paragraphCount: Int? = nil) -> Report {
        let share = bulletsSharePercent(rewrite)
        let mainCount = mainBulletCount(rewrite)
        return Report(
            bulletsSharePercent: share,
            mainBulletCount: mainCount,
            maxDepth: maxDepth(rewrite),
            overlongBulletCount: overlongBullets(rewrite).count,
            meetsBulletsShareGoal: share >= 80,
            meetsParagraphCoverage: paragraphCount.map { coversEveryParagraph(mainBulletCount: mainCount, paragraphCount: $0) }
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
