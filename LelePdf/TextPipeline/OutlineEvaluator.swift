import Foundation

/// Evaluates whether a PDF's built-in outline (`PDFOutline`) is "useful" for
/// the Chapters sidebar, per the rules of SPEC §5.3. Pure and PDFKit-free, so
/// it is testable with synthetic entries (`LelePdfTests/OutlineEvaluatorTests.swift`);
/// the extraction of the raw entries from `PDFDocument.outlineRoot` lives in
/// `NativeOutline` (MainActor, requires PDFKit).
enum OutlineEvaluator {
    /// A raw entry of the native outline, before becoming a `TocEntry`.
    /// `page` is `nil` if the destination cannot be resolved.
    struct RawEntry: Sendable, Equatable {
        let title: String
        let level: Int
        let page: Int?
        /// Vertical position of the destination (page space, v2.3 §8
        /// `pageY`): from the point of the native outline's
        /// `PDFDestination`, when present and plausible. `nil` if the outline
        /// specifies no point (or gives an invalid one); the caller falls back
        /// to the page jump alone.
        let pageY: Double?

        init(title: String, level: Int = 1, page: Int?, pageY: Double? = nil) {
            self.title = title
            self.level = level
            self.page = page
            self.pageY = pageY
        }
    }

    /// SPEC §5.3 rules, applied in order (it exits at the first that fails):
    /// 1. at least 3 entries;
    /// 2. at least 70% of the entries point to a valid page (`0..<pageCount`);
    /// 3. no label resembles a file name;
    /// 4. the entries cover more than 20% of the pages.
    ///
    /// **Definition of coverage** [TECHNICAL CHOICE, SPEC §7.4 leaves room]:
    /// the span of pages from the first to the last entry with a valid page
    /// (`page_max - page_min + 1`) divided by `pageCount`. The span is
    /// preferred over the count of distinct pages referenced because an
    /// outline with few entries scattered across the whole book (typical of
    /// a chapters-only outline) must still count as "wide coverage", while
    /// an outline with many entries clustered only in the first pages
    /// (typical of a cover page with a summary) must not pass.
    static func isUseful(entries: [RawEntry], pageCount: Int) -> Bool {
        guard pageCount > 0 else { return false }
        guard entries.count >= 3 else { return false }

        let validEntries = entries.filter { isValidPage($0.page, pageCount: pageCount) }
        let validRatio = Double(validEntries.count) / Double(entries.count)
        guard validRatio >= 0.7 else { return false }

        guard !entries.contains(where: { looksLikeFileName($0.title) }) else { return false }

        let validPages = validEntries.compactMap(\.page)
        guard let minPage = validPages.min(), let maxPage = validPages.max() else { return false }
        let coverage = Double(maxPage - minPage + 1) / Double(pageCount)
        guard coverage > 0.20 else { return false }

        return true
    }

    static func isValidPage(_ page: Int?, pageCount: Int) -> Bool {
        guard let page else { return false }
        return page >= 0 && page < pageCount
    }

    /// SPEC §5.3: `^EN_`, `.pdf`, "untitled", "file" (case-insensitive,
    /// "file" as a whole word so as not to discard, for example, "Profile" or
    /// "File system" meant as a concept).
    static func looksLikeFileName(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "^EN_", options: .regularExpression) != nil { return true }
        if trimmed.range(of: "\\.pdf", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if trimmed.range(of: "untitled", options: .caseInsensitive) != nil { return true }
        if trimmed.range(of: "\\bfile\\b", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }
}
