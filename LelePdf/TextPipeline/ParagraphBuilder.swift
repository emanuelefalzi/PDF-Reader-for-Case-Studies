import Foundation

/// Paragraphs (SPEC §7.3): separated by a vertical gap greater than 0.6
/// times the line spacing or by a first-line indent; a paragraph continues
/// onto the next page if the last line does not end with final punctuation
/// and the following page starts in lowercase. It also tracks the current
/// section path (headings active per level), for the rule "a block never
/// crosses a section boundary".
enum ParagraphBuilder {
    static func build(pages: [CleanPage], excludedLines: [Int: Set<Int>], headings: [Heading]) -> [Paragraph] {
        let lineSpacing = estimateLineSpacing(pages: pages, excludedLines: excludedLines)
        let headingKeys = Dictionary(uniqueKeysWithValues: headings.map { (Key(page: $0.pageIndex, line: $0.lineIndex), $0) })

        var sectionStack: [Int: String] = [:]
        var paragraphs: [Paragraph] = []
        var current: Paragraph?
        var previousLine: CleanLine?
        var previousPage: Int?

        func flush() {
            if let paragraph = current, paragraph.wordCount > 0 { paragraphs.append(paragraph) }
            current = nil
        }

        for page in pages {
            let excluded = excludedLines[page.pageIndex] ?? []
            for line in page.contentLines where !excluded.contains(line.lineIndex) {
                if let heading = headingKeys[Key(page: page.pageIndex, line: line.lineIndex)] {
                    flush()
                    sectionStack = sectionStack.filter { $0.key < heading.level }
                    sectionStack[heading.level] = heading.text
                    previousLine = nil
                    previousPage = page.pageIndex
                    continue
                }

                let text = line.text.string
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                let startsNew = shouldStartNewParagraph(
                    line: line, page: page.pageIndex,
                    previousLine: previousLine, previousPage: previousPage,
                    current: current, lineSpacing: lineSpacing
                )
                if startsNew || current == nil {
                    flush()
                    current = Paragraph(parts: [], sectionPath: sortedPath(sectionStack))
                }
                append(line, page: page.pageIndex, to: &current!)
                previousLine = line
                previousPage = page.pageIndex
            }
        }
        flush()
        return paragraphs
    }

    private struct Key: Hashable { let page: Int; let line: Int }

    private static func shouldStartNewParagraph(
        line: CleanLine, page: Int,
        previousLine: CleanLine?, previousPage: Int?,
        current: Paragraph?, lineSpacing: CGFloat
    ) -> Bool {
        guard let previousLine, let previousPage else { return true }

        if previousPage == page {
            let verticalGap = previousLine.rect.minY - line.rect.maxY
            if verticalGap > lineSpacing * 0.6 { return true }
            if line.rect.minX - previousLine.rect.minX > max(lineSpacing * 1.5, 6) { return true }
            return false
        }

        // Page change: continue only if the last line did not end with
        // final punctuation and this line starts in lowercase.
        guard let current, let lastPart = current.parts.last else { return true }
        let endsSentence = endsWithSentencePunctuation(lastPart.text.string)
        let startsLower = startsLowercase(line.text.string)
        // Continue (no new paragraph) only if the last line did not end with
        // final punctuation and this one starts in lowercase.
        return !(!endsSentence && startsLower)
    }

    private static func append(_ line: CleanLine, page: Int, to paragraph: inout Paragraph) {
        if let last = paragraph.parts.last, last.pageIndex == page {
            var text = last.text
            if let lastOrig = text.last?.orig { text.append(IndexedChar(ch: " ", orig: lastOrig)) }
            text.append(contentsOf: line.text)
            var rects = last.lineRects
            rects.append(line.rect)
            paragraph.parts[paragraph.parts.count - 1] = ParagraphPagePart(pageIndex: page, text: text, lineRects: rects)
        } else {
            paragraph.parts.append(ParagraphPagePart(pageIndex: page, text: line.text, lineRects: [line.rect]))
        }
    }

    private static func sortedPath(_ stack: [Int: String]) -> [String] {
        stack.sorted { $0.key < $1.key }.map(\.value)
    }

    private static func estimateLineSpacing(pages: [CleanPage], excludedLines: [Int: Set<Int>]) -> CGFloat {
        var gaps: [CGFloat] = []
        for page in pages {
            let excluded = excludedLines[page.pageIndex] ?? []
            let lines = page.contentLines.filter { !excluded.contains($0.lineIndex) }
            guard lines.count > 1 else { continue }
            for index in 1 ..< lines.count {
                let gap = lines[index - 1].rect.minY - lines[index].rect.maxY
                if gap > 0, gap < lines[index].fontSize * 3 { gaps.append(gap) }
            }
        }
        guard !gaps.isEmpty else { return 4 }
        return gaps.sorted()[gaps.count / 2]
    }

    static func endsWithSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".!?\"'\u{201D}\u{2019})]".contains(last)
    }

    static func startsLowercase(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespaces).first else { return false }
        return first.isLowercase
    }
}
