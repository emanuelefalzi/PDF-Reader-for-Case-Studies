import Foundation

/// Removal of headers, footers and page numbers (SPEC §7.2.1): lines in
/// the top or bottom 8% of the page whose normalized text (no spaces or
/// digits, lowercase) repeats on at least 30% of the pages. Before removing
/// them, it derives the chapter names from them (SPEC §7.4 item 1, e.g.
/// "CHAPTER 2" in the Draghi report).
///
/// It groups by normalized **prefix** instead of exact equality: the Draghi
/// header changes its tail per chapter
/// ("… — PA RT A \| C H A PT E R 2" vs "… CHAPTER 3"), but the report title at
/// the start is always the same, and that is enough to reach the 30%
/// repetition required for 95% removal (SPEC §11 row M2).
enum HeaderFooterRemover {
    struct Output: Sendable {
        var pages: [CleanPage]
        var chapterCandidates: [TocCandidate]
    }

    static let marginFraction: CGFloat = 0.08
    static let minRepeatFraction = 0.30
    static let clusterPrefixLength = 18

    static func apply(to pages: [CleanPage]) -> Output {
        guard !pages.isEmpty else { return Output(pages: pages, chapterCandidates: []) }

        struct Candidate { let pageIndex: Int; let lineIndex: Int; let normalized: String; let raw: String }
        var candidates: [Candidate] = []
        for page in pages {
            let topThreshold = page.pageRect.minY + page.pageRect.height * (1 - marginFraction)
            let bottomThreshold = page.pageRect.minY + page.pageRect.height * marginFraction
            for line in page.lines {
                guard line.rect.minY >= topThreshold || line.rect.maxY <= bottomThreshold else { continue }
                let raw = line.text.string
                candidates.append(Candidate(pageIndex: page.pageIndex, lineIndex: line.lineIndex, normalized: normalize(raw), raw: raw))
            }
        }
        guard !candidates.isEmpty else { return Output(pages: pages, chapterCandidates: []) }

        let pageCount = pages.count
        var toRemove = Set<PagePosition>()
        var chapterCandidates: [TocCandidate] = []

        let nonEmpty = candidates.filter { !$0.normalized.isEmpty }
        let empty = candidates.filter { $0.normalized.isEmpty }

        var groups: [String: [Candidate]] = [:]
        for candidate in nonEmpty {
            groups[String(candidate.normalized.prefix(clusterPrefixLength)), default: []].append(candidate)
        }
        for group in groups.values {
            let distinctPages = Set(group.map(\.pageIndex)).count
            guard Double(distinctPages) / Double(pageCount) >= minRepeatFraction else { continue }
            for candidate in group { toRemove.insert(PagePosition(page: candidate.pageIndex, line: candidate.lineIndex)) }
            chapterCandidates.append(contentsOf: extractChapterCandidates(group.map { ($0.pageIndex, $0.raw) }))
        }

        // Lines that stay "empty" after stripping digits and spaces: lone
        // page numbers, or lone separators.
        let emptyPages = Set(empty.map(\.pageIndex)).count
        if !empty.isEmpty, Double(emptyPages) / Double(pageCount) >= minRepeatFraction {
            for candidate in empty { toRemove.insert(PagePosition(page: candidate.pageIndex, line: candidate.lineIndex)) }
        }

        var resultPages = pages
        for pageOffset in resultPages.indices {
            for lineOffset in resultPages[pageOffset].lines.indices {
                let line = resultPages[pageOffset].lines[lineOffset]
                if toRemove.contains(PagePosition(page: line.pageIndex, line: line.lineIndex)) {
                    resultPages[pageOffset].lines[lineOffset].removedAsHeaderFooter = true
                }
            }
        }
        return Output(pages: resultPages, chapterCandidates: dedupe(chapterCandidates))
    }

    private struct PagePosition: Hashable { let page: Int; let line: Int }

    /// Without spaces, without digits, lowercase: `CharacterSet`/Unicode
    /// handles accented letters etc. on its own.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace && !$0.isNumber })
    }

    private static func extractChapterCandidates(_ lines: [(page: Int, raw: String)]) -> [TocCandidate] {
        var firstPageByNumber: [String: Int] = [:]
        for (page, raw) in lines {
            guard let number = chapterNumber(in: raw) else { continue }
            firstPageByNumber[number] = min(firstPageByNumber[number] ?? page, page)
        }
        return firstPageByNumber.map { number, page in
            TocCandidate(title: "Chapter \(number)", page: page, levelHint: 1, source: .runningHeader)
        }
    }

    /// Headers often have spaced letters ("C H A PT E R 2"): all spaces are
    /// removed before looking for the chapter number.
    private static func chapterNumber(in raw: String) -> String? {
        let despaced = raw.replacingOccurrences(of: " ", with: "")
        guard let range = despaced.range(of: "chapter[0-9]+", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let digits = despaced[range].filter(\.isNumber)
        return digits.isEmpty ? nil : String(digits)
    }

    private static func dedupe(_ candidates: [TocCandidate]) -> [TocCandidate] {
        var seen = Set<String>()
        return candidates.sorted { $0.page < $1.page }.filter { seen.insert($0.title).inserted }
    }
}
