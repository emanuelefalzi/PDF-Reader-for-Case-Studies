import Foundation

/// Exhibits, tables and figures (SPEC §7.3): zones that start with a
/// caption ("Exhibit N", "Figure N", "Table N", "Source:") or lines dense
/// with short tokens (more than 40% numeric or many repetitions, like
/// "J&J J&J J&J…" in the Merck case). Excluded from paragraphs/blocks.
enum ExhibitDetector {
    struct Output: Sendable {
        /// Lines (by line index on the page) to exclude from the paragraph
        /// flow.
        var excludedLinesByPage: [Int: Set<Int>]
        var exhibits: [ExhibitRef]
    }

    static func detect(pages: [CleanPage]) -> Output {
        var exhibits: [ExhibitRef] = []
        var excluded: [Int: Set<Int>] = [:]

        for page in pages {
            let lines = page.contentLines
            var index = 0
            while index < lines.count {
                let text = lines[index].text.string.trimmingCharacters(in: .whitespaces)
                if let label = captionLabel(text) {
                    exhibits.append(ExhibitRef(label: label, page: page.pageIndex))
                    index = markZone(from: index, lines: lines, page: page.pageIndex, into: &excluded)
                } else if startsWithSource(text) || isDenseNumericLine(text) {
                    excluded[page.pageIndex, default: []].insert(lines[index].lineIndex)
                    index += 1
                } else {
                    index += 1
                }
            }
        }
        return Output(excludedLinesByPage: excluded, exhibits: exhibits)
    }

    /// Marks the caption line and the following ones until a normal prose
    /// line is found again (SPEC: the Exhibit zone includes the caption, the
    /// table and the "Source:" notes that follow it).
    private static func markZone(from start: Int, lines: [CleanLine], page: Int, into excluded: inout [Int: Set<Int>]) -> Int {
        var j = start
        while j < lines.count {
            excluded[page, default: []].insert(lines[j].lineIndex)
            j += 1
            if j < lines.count, isNormalProseLine(lines[j].text.string) { break }
        }
        return j
    }

    private static func captionLabel(_ text: String) -> String? {
        for kind in ["Exhibit", "Figure", "Table"] {
            if let range = text.range(of: "^\(kind)\\s+[0-9]+", options: [.regularExpression, .caseInsensitive]) {
                return String(text[range])
            }
        }
        return nil
    }

    private static func startsWithSource(_ text: String) -> Bool {
        text.range(of: "^source:", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isDenseNumericLine(_ text: String) -> Bool {
        let tokens = text.split(separator: " ").filter { !$0.isEmpty }
        guard tokens.count >= 3 else { return false }

        let numericTokens = tokens.filter { $0.contains(where: \.isNumber) }
        if Double(numericTokens.count) / Double(tokens.count) > 0.4 { return true }

        let counts = Dictionary(grouping: tokens, by: { $0 }).mapValues(\.count)
        if let maxCount = counts.values.max(), tokens.count >= 4, Double(maxCount) / Double(tokens.count) > 0.4 {
            return true
        }
        return false
    }

    private static func isNormalProseLine(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        return words.count >= 6 && !isDenseNumericLine(text) && !startsWithSource(text)
    }
}
