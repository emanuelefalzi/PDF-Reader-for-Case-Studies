import CryptoKit
import Foundation

/// Block rule [a product decision, replacing the original SPEC §7.3 rule
/// "subsection or group of paragraphs by length"]: **one block = one
/// section**, from the lowest-level heading available to the next heading of
/// equal or higher level (`groupBySectionPath`, unchanged:
/// `Paragraph.sectionPath` is already the stack of active level 1..3
/// headings, so a change at ANY level, the lowest included, closes the
/// current group). A section up to `sectionMaxWords` words is a single
/// block; a longer one is split into **numbered parts** ("3.2 · part 2 of 3",
/// `BlockLabeling`), groups of consecutive paragraphs from `partMinWords` to
/// `partMaxWords`; a single paragraph over `partMaxWords` is a part of its
/// own. A block never crosses a section boundary and never cuts a
/// paragraph.
enum BlockSegmenter {
    static let sectionMaxWords = 700
    static let partMinWords = 250
    static let partMaxWords = 600

    static func segment(paragraphs: [Paragraph]) -> [TextBlock] {
        groupBySectionPath(paragraphs).flatMap { segmentSection($0, caps: legacyCaps) }
    }

    private static let legacyCaps = SummaryGranularity.Caps(sectionMaxWords: sectionMaxWords, partMinWords: partMinWords, partMaxWords: partMaxWords)

    // MARK: - Granularity chosen from the contents (T1-T4)

    /// A block runs from a contents entry (`tocEntries`, T1-T4) of the chosen
    /// level (or higher, i.e. a lower number) to the next one of the same
    /// level or higher, NEVER from the internal `Paragraph.sectionPath` used
    /// by `segment(paragraphs:)` above (that remains today's path,
    /// unchanged, for a `documento.json` with no granularity chosen).
    /// `.paragraph` does not use `tocEntries` at all: each paragraph is
    /// already the finest possible block.
    static func segment(paragraphs: [Paragraph], tocEntries: [TocEntry], granularity: SummaryGranularity) -> [TextBlock] {
        let caps = granularity.caps
        guard let maxLevel = granularity.tocLevelThreshold else {
            // `.paragraph`: one block per paragraph. A single pathologically
            // long paragraph (rare) is still subject to the granularity's
            // length cap, with the same split into numbered parts as
            // `segmentSection`: never a single call to Claude on an enormous
            // text even at this granularity.
            return paragraphs.flatMap { segmentSection([$0], caps: caps) }
        }
        return groupByTocLevel(paragraphs, tocEntries: tocEntries, maxLevel: maxLevel).flatMap { segmentSection($0, caps: caps) }
    }

    /// Groups the paragraphs by the most recent contents entry (level ≤
    /// `maxLevel`) in document-position order; `tocEntries` is already in
    /// position order (`ManualToc.sorted`, the single source of truth for
    /// ordering, never recomputed here). A declared approximation (the same
    /// principle already used for interleaving headings/blocks,
    /// `AnalysisController.documentOrderSegments`/`RewriteExportModel`): the
    /// boundary is at the START PAGE of the paragraph/entry, not at a finer
    /// Y; a contents entry on the SAME start page as a paragraph still opens
    /// the new section (the entry "comes first" by definition, never the
    /// other way round). Paragraphs before any useful entry (for example the
    /// cover page) remain a group of their own, as `BlockLabeling`'s
    /// "chapter 0".
    private static func groupByTocLevel(_ paragraphs: [Paragraph], tocEntries: [TocEntry], maxLevel: Int) -> [[Paragraph]] {
        let boundaries = tocEntries.filter { $0.level <= maxLevel }.sorted { $0.page < $1.page }
        guard !boundaries.isEmpty else { return paragraphs.isEmpty ? [] : [paragraphs] }

        var result: [[Paragraph]] = []
        var current: [Paragraph] = []
        var boundaryIndex = -1
        for paragraph in paragraphs {
            while boundaryIndex + 1 < boundaries.count, boundaries[boundaryIndex + 1].page <= paragraph.pageStart {
                if !current.isEmpty { result.append(current) }
                current = []
                boundaryIndex += 1
            }
            current.append(paragraph)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func groupBySectionPath(_ paragraphs: [Paragraph]) -> [[Paragraph]] {
        var result: [[Paragraph]] = []
        var current: [Paragraph] = []
        var currentPath: [String]?
        for paragraph in paragraphs {
            if paragraph.sectionPath != currentPath {
                if !current.isEmpty { result.append(current) }
                current = []
                currentPath = paragraph.sectionPath
            }
            current.append(paragraph)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func segmentSection(_ paragraphs: [Paragraph], caps: SummaryGranularity.Caps) -> [TextBlock] {
        guard !paragraphs.isEmpty else { return [] }
        let totalWords = paragraphs.reduce(0) { $0 + $1.wordCount }
        if totalWords <= caps.sectionMaxWords {
            return [makeBlock(from: paragraphs, part: nil)]
        }

        var groups: [[Paragraph]] = []
        var currentGroup: [Paragraph] = []
        var currentWords = 0

        func flushGroup() {
            if !currentGroup.isEmpty { groups.append(currentGroup) }
            currentGroup = []
            currentWords = 0
        }

        for paragraph in paragraphs {
            if paragraph.wordCount > caps.partMaxWords {
                flushGroup()
                groups.append([paragraph])
                continue
            }
            if currentWords >= caps.partMinWords, currentWords + paragraph.wordCount > caps.partMaxWords {
                flushGroup()
            }
            currentGroup.append(paragraph)
            currentWords += paragraph.wordCount
        }
        flushGroup()

        // A section split into several parts: numbered in document order
        // ("part 1 of N" .. "part N of N"), never mid-paragraph (guaranteed
        // above) and never straddling a section boundary (the `paragraphs`
        // here already all belong to the same section, by construction of
        // `groupBySectionPath`).
        let count = groups.count
        return groups.enumerated().map { index, group in
            makeBlock(from: group, part: count > 1 ? (index: index + 1, count: count) : nil)
        }
    }

    /// Builds `cleanText` and `spans` in a single pass, never materializing
    /// an intermediate array as large as the whole block (memory): the
    /// previous version built `flat` (one tuple per character), then
    /// `flat.map { $0.ch.ch }` to get `cleanText`: two complete copies of the
    /// block's text, besides `charMap` (which is really needed and is the
    /// only one retained in `TextBlock.spans`). On a document of hundreds of
    /// pages this needlessly doubled/tripled the segmentation's memory peak
    /// (measured). The exact same result: `lastPage`/`lastOrig` follow
    /// exactly what `flat.last` would have been in the previous version (the
    /// last character emitted, separator included), and a `span` closes as
    /// soon as the page of the emitted character changes, the same split of
    /// `flat` into contiguous groups per page.
    private static func makeBlock(from paragraphs: [Paragraph], part: (index: Int, count: Int)?) -> TextBlock {
        // Estimate only the counts (no copy of characters) to reserve
        // `cleanText` in one go: without `reserveCapacity` every
        // `append(_:Character)` regrows the string by doubling (repeated
        // reallocations, several differently sized buckets touched in the
        // allocator) instead of the single right-sized allocation that
        // `String(flat.map { ... })` made in the previous version; measured to
        // worsen, not improve, the footprint of the whole app.
        let estimatedChars = paragraphs.reduce(0) { total, paragraph in
            total + paragraph.parts.reduce(0) { $0 + $1.text.count } + 2
        }
        var cleanText = ""
        cleanText.reserveCapacity(estimatedChars)
        var spans: [BlockPageSpan] = []
        var currentSpanPage: Int?
        var currentCharMap: [Int] = []
        var cleanIndex = 0
        var lastPage: Int?
        var lastOrig: Int?

        func flushSpan() {
            guard let page = currentSpanPage, !currentCharMap.isEmpty else { return }
            spans.append(BlockPageSpan(page: page, cleanStart: cleanIndex - currentCharMap.count, cleanLength: currentCharMap.count, charMap: currentCharMap))
            currentCharMap = []
        }

        func appendChar(_ ch: Character, page: Int, orig: Int) {
            if currentSpanPage != page {
                flushSpan()
                currentSpanPage = page
            }
            currentCharMap.append(orig)
            cleanText.append(ch)
            cleanIndex += 1
            lastPage = page
            lastOrig = orig
        }

        for paragraph in paragraphs {
            if let lastPage, let lastOrig {
                appendChar("\n", page: lastPage, orig: lastOrig)
                appendChar("\n", page: lastPage, orig: lastOrig)
            }
            for (partIndex, part) in paragraph.parts.enumerated() {
                if partIndex > 0 {
                    let page = lastPage ?? part.pageIndex
                    let orig = lastOrig ?? part.text.first?.orig ?? 0
                    appendChar(" ", page: page, orig: orig)
                }
                for indexedChar in part.text { appendChar(indexedChar.ch, page: part.pageIndex, orig: indexedChar.orig) }
            }
        }
        flushSpan()

        let sectionPath = paragraphs.first?.sectionPath ?? []
        let pageStart = paragraphs.first?.pageStart ?? 0
        let pageEnd = paragraphs.last?.pageEnd ?? pageStart
        let words = cleanText.split(whereSeparator: \.isWhitespace).count

        var lineRectsByPage: [Int: [PageRect]] = [:]
        for paragraph in paragraphs {
            for part in paragraph.parts {
                lineRectsByPage[part.pageIndex, default: []].append(contentsOf: part.lineRects)
            }
        }

        return TextBlock(
            id: makeId(sectionPath: sectionPath, cleanText: cleanText, pageStart: pageStart),
            sectionPath: sectionPath,
            pageStart: pageStart,
            pageEnd: pageEnd,
            cleanText: cleanText,
            textHash: sha256Hex(cleanText, length: 64),
            words: words,
            spans: spans,
            lineRectsByPage: lineRectsByPage,
            partIndex: part?.index,
            partCount: part?.count
        )
    }

    /// Stable block id (SPEC §7.3): a hash of the section path, the first 60
    /// characters of the clean text and the start page. If the division
    /// algorithm changes, `textHash` (not the id) makes the saved analyses
    /// reattach.
    private static func makeId(sectionPath: [String], cleanText: String, pageStart: Int) -> String {
        let input = sectionPath.joined(separator: "/") + "|" + String(cleanText.prefix(60)) + "|" + String(pageStart)
        return sha256Hex(input, length: 16)
    }

    private static func sha256Hex(_ text: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(length))
    }
}
