import Foundation

/// Pure orchestrator of the pipeline (SPEC §6.2 "TextPipeline", §7.2-§7.3):
/// it receives the `PageLayout`s already extracted on the MainActor
/// (`LineExtractor`) and produces cleaning, structure and blocks. No PDFKit
/// access here: only `Sendable` structs in and out (SPEC §6.3).
///
/// M1 had only the module comment here: extraction, cleaning and blocks
/// all arrive in M2.
actor TextPipeline {
    struct Output: Sendable {
        let headings: [Heading]
        let tocCandidates: [TocCandidate]
        let exhibits: [ExhibitRef]
        let blocks: [TextBlock]
        let removedHeaderFooterLines: [Int: [PageRect]]
        /// Held in memory (never persisted, recomputable by the pipeline like
        /// `lineRectsByPage`) ONLY because
        /// `BlockSegmenter.segment(paragraphs:tocEntries:granularity:)` must be
        /// able to regroup the same paragraphs with a different boundary when
        /// the user changes the summary granularity AFTER the open, without
        /// redoing the entire extraction/cleaning (`HeaderFooterRemover`/
        /// `HyphenationJoiner`/`ExhibitDetector`/`HeadingDetector`, the real
        /// cost of the pipeline).
        let paragraphs: [Paragraph]
    }

    func process(layouts: [PageLayout]) -> Output {
        // `rawPages` and `headerResult` in a separate `do` block (memory):
        // they are only an intermediate step toward `pages`/
        // `chapterCandidates` and are no longer needed after these two lines,
        // but being function-level `let`s they would stay alive until the final
        // `return` in an unoptimized build (ARC releases a local variable at
        // the end of its BLOCK, not at its last use), keeping the same data as
        // `pages` alive for longer than needed through the copy-on-write shared
        // `CleanPage.lines`. Closing the scope here releases them right after
        // use.
        var pages: [CleanPage]
        let chapterCandidates: [TocCandidate]
        do {
            let rawPages = layouts.map(CleanPage.init(layout:))
            let headerResult = HeaderFooterRemover.apply(to: rawPages)
            chapterCandidates = headerResult.chapterCandidates
            pages = HyphenationJoiner.apply(to: headerResult.pages)
        }

        // Computed right away, as soon as `pages` exists, instead of at the
        // end of the function (memory, SPEC §9): they are the only two things
        // still needed from `pages` AFTER the paragraphs/blocks are built
        // (below), and they are light (short strings per page, rectangles
        // only) compared to the whole `pages` (character-by-character
        // `IndexedText` of every line of every page). Computing them now lets
        // `pages` be released (`pages = []` below) BEFORE the heaviest phase
        // (`BlockSegmenter`), instead of keeping it alive to the bottom of the
        // function just for these two reads; it halved the pipeline's memory
        // peak on a long document (measured).
        let bodyByPage: [Int: String] = Dictionary(uniqueKeysWithValues: pages.map { page in
            (page.pageIndex, page.contentLines.map { $0.text.string }.joined(separator: " "))
        })
        var removedLines: [Int: [PageRect]] = [:]
        for page in pages {
            let removed = page.lines.filter(\.removedAsHeaderFooter).map(\.rect)
            if !removed.isEmpty { removedLines[page.pageIndex] = removed }
        }

        // Exhibits must be detected before headings (not after, as originally):
        // without their excluded lines, a short bold caption such as
        // "Exhibit 1" satisfies the "short bold line" rule and becomes a bogus
        // heading, which then breaks the blocks' section boundaries (M2/M4
        // fix).
        let exhibitResult = ExhibitDetector.detect(pages: pages)

        let bodyFontSize = HeadingDetector.bodyFontSize(pages)
        let headings = HeadingDetector.detect(pages: pages, bodyFontSize: bodyFontSize, excludedLines: exhibitResult.excludedLinesByPage)

        var paragraphs = ParagraphBuilder.build(pages: pages, excludedLines: exhibitResult.excludedLinesByPage, headings: headings)
        if paragraphs.isEmpty {
            paragraphs = FallbackSegmenter.paragraphs(pages: pages, excludedLines: exhibitResult.excludedLinesByPage)
        }
        // Explicit release (see comment above): from here on the function
        // uses only `paragraphs`/`blocks`, never `pages` again.
        pages = []

        let blocks = BlockSegmenter.segment(paragraphs: paragraphs)

        // All the headings found become candidates for the generated contents
        // (SPEC §7.4 item 1: "the candidates are the headings found at §7.3"),
        // not just level-1 ones: that was why the Merck case's contents had a
        // single entry (the document title, the only heading left at level 1
        // because of the bug above); the real sections (level 2/3 in the old,
        // wrong ranking) were discarded here. Claude still cleans up the false
        // positives and fixes the levels (`Resources/Prompts/toc.md`).
        let headingCandidates = headings.map {
            TocCandidate(title: $0.text, page: $0.pageIndex, levelHint: $0.level, source: .heading)
        }
        let tocCandidates = fillFollowingWords(chapterCandidates + headingCandidates, bodyByPage: bodyByPage)
            .sorted { $0.page < $1.page }

        return Output(
            headings: headings,
            tocCandidates: tocCandidates,
            exhibits: exhibitResult.exhibits,
            blocks: blocks,
            removedHeaderFooterLines: removedLines,
            paragraphs: paragraphs
        )
    }

    /// First ~20 words of the body text of the candidate's page (SPEC §7.4:
    /// it is all the context Claude will receive to clean them up, M4).
    private func fillFollowingWords(_ candidates: [TocCandidate], bodyByPage: [Int: String]) -> [TocCandidate] {
        return candidates.map { candidate in
            var candidate = candidate
            if candidate.followingWords.isEmpty {
                let words = (bodyByPage[candidate.page] ?? "").split(whereSeparator: \.isWhitespace).prefix(20)
                candidate.followingWords = words.joined(separator: " ")
            }
            return candidate
        }
    }
}
