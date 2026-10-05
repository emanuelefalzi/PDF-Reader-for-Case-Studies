import Foundation

/// Fallback (SPEC §7.3): when no reliable headings or paragraphs are found,
/// the blocks are groups of lines of about 400 words that end at a sentence
/// end. Used by `TextPipeline` only if `ParagraphBuilder` produces no useful
/// paragraph for the whole document.
enum FallbackSegmenter {
    static let targetWords = 400

    static func paragraphs(pages: [CleanPage], excludedLines: [Int: Set<Int>]) -> [Paragraph] {
        var result: [Paragraph] = []
        var currentParts: [ParagraphPagePart] = []
        var currentWords = 0

        func flush() {
            guard !currentParts.isEmpty else { return }
            result.append(Paragraph(parts: currentParts, sectionPath: []))
            currentParts = []
            currentWords = 0
        }

        for page in pages {
            let excluded = excludedLines[page.pageIndex] ?? []
            for line in page.contentLines where !excluded.contains(line.lineIndex) {
                let text = line.text.string
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                if var last = currentParts.last, last.pageIndex == page.pageIndex {
                    if let lastOrig = last.text.last?.orig { last.text.append(IndexedChar(ch: " ", orig: lastOrig)) }
                    last.text.append(contentsOf: line.text)
                    last.lineRects.append(line.rect)
                    currentParts[currentParts.count - 1] = last
                } else {
                    currentParts.append(ParagraphPagePart(pageIndex: page.pageIndex, text: line.text, lineRects: [line.rect]))
                }
                currentWords += text.split(whereSeparator: \.isWhitespace).count

                if currentWords >= targetWords, ParagraphBuilder.endsWithSentencePunctuation(text) {
                    flush()
                }
            }
        }
        flush()
        return result
    }
}
