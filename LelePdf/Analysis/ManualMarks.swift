import Foundation

/// Manual marks and links (SPEC §5.7): pure creation/re-derivation logic,
/// independent of PDFKit/Store. `AnalysisControllerManualMarks` (MainActor)
/// calls it with data already resolved by `ManualSelectionResolver`.
enum ManualMarks {
    static func nextMarkId(in marks: [Mark]) -> String {
        let maxExisting = marks.compactMap { mark -> Int? in
            guard mark.id.hasPrefix("m") else { return nil }
            return Int(mark.id.dropFirst())
        }.max() ?? 0
        return "m\(maxExisting + 1)"
    }

    static func nextLinkId(in links: [Link]) -> String {
        let maxExisting = links.compactMap { link -> Int? in
            guard link.id.hasPrefix("l") else { return nil }
            return Int(link.id.dropFirst())
        }.max() ?? 0
        return "l\(maxExisting + 1)"
    }

    /// New manual mark (SPEC §5.7 "Add"): the term is the selected text with
    /// normalized whitespace (not lowercased: case-insensitive comparison
    /// remains `TermRegistry`'s job). The term registry decides `termId`
    /// (reusing one if the same concept already exists, otherwise minting a
    /// new one).
    static func makeMark(
        text: String, type: MarkType, page: Int, range: MarkRange, blockId: String,
        existingTerms: [String: TermRecord], existingMarks: [Mark]
    ) -> (mark: Mark, newTerm: (id: String, record: TermRecord)?) {
        let canonicalTerm = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let resolution = TermRegistry.resolve(term: canonicalTerm, proposedTermId: nil, in: existingTerms)
        let mark = Mark(id: nextMarkId(in: existingMarks), termId: resolution.termId, type: type, text: text, source: .manual, page: page, range: range, hidden: false)
        let newTerm = resolution.isNew ? (resolution.termId, TermRecord(term: canonicalTerm, type: type, firstBlockId: blockId)) : nil
        return (mark, newTerm)
    }

    /// SPEC §5.7 "Rewrite: if the manually marked term appears in the block's
    /// rewrite (case-insensitive), it is marked there too": finds every
    /// occurrence of a manual term inside segments that are still `.plain` (it
    /// does not touch those already `.marked` by a Claude mark: an explicit
    /// `{{mX|...}}` always wins). A pure rendering function (computed at
    /// render, not rewriting stored text), never persisted.
    static func highlightManualTerms(in segments: [AnalysisController.ResolvedSegment], manualMarks: [Mark]) -> [AnalysisController.ResolvedSegment] {
        // Fix for the manual-mark hover: the real manual mark's `markId` is
        // carried all the way here. Previously only `termId` was kept, so this
        // render-time occurrence in the rewrite had no `markId` of its own,
        // and `HoverLinking.state` lit it up only as `.linked` instead of
        // `.hover` when hovering the mark in the PDF (never as the "exact"
        // counterpart): the highlight came out at reduced intensity on a mark
        // that should light up fully on the other side, as SPEC §5.8 requires
        // ("it shows on the corresponding mark on the other side").
        let terms = manualMarks
            .map { (text: $0.text, termId: $0.termId, type: $0.type, markId: $0.id) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !terms.isEmpty else { return segments }
        return segments.flatMap { segment -> [AnalysisController.ResolvedSegment] in
            guard case .plain(let text) = segment else { return [segment] }
            return highlight(text, terms: terms)
        }
    }

    private static func highlight(_ text: String, terms: [(text: String, termId: String, type: MarkType, markId: String)]) -> [AnalysisController.ResolvedSegment] {
        guard !text.isEmpty else { return [] }
        // The first occurrence (leftmost; on equal start, the longest) of any
        // of the manual terms, case-insensitive.
        var best: (range: Range<String.Index>, term: (text: String, termId: String, type: MarkType, markId: String))?
        for term in terms {
            guard let range = text.range(of: term.text, options: [.caseInsensitive]) else { continue }
            if let current = best {
                if range.lowerBound < current.range.lowerBound
                    || (range.lowerBound == current.range.lowerBound && range.upperBound > current.range.upperBound) {
                    best = (range, term)
                }
            } else {
                best = (range, term)
            }
        }
        guard let match = best else { return [.plain(text)] }
        var result: [AnalysisController.ResolvedSegment] = []
        if match.range.lowerBound > text.startIndex {
            result.append(.plain(String(text[text.startIndex ..< match.range.lowerBound])))
        }
        result.append(.marked(text: String(text[match.range]), markId: match.term.markId, termId: match.term.termId, type: match.term.type))
        result.append(contentsOf: highlight(String(text[match.range.upperBound...]), terms: terms))
        return result
    }
}

/// Links derived from manual underline/arrow marks (SPEC §5.7 "they become
/// links if the same sentence has a node before and one after"; a sentence is
/// the clean text split on . ! ? followed by a space/newline). Pure, works in
/// `Character` units (not UTF-16), the same convention as
/// `Mark.range`/`MarkMatcher`.
enum ManualLinkDerivation {
    /// Sentences of the clean text, as `Character` ranges in `cleanText`.
    static func sentenceRanges(in cleanText: String) -> [NSRange] {
        let chars = Array(cleanText)
        guard !chars.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var start = 0
        var i = 0
        while i < chars.count {
            if chars[i] == "." || chars[i] == "!" || chars[i] == "?" {
                let next = i + 1
                if next >= chars.count || chars[next].isWhitespace || chars[next].isNewline {
                    ranges.append(NSRange(location: start, length: next - start))
                    start = next
                }
            }
            i += 1
        }
        if start < chars.count {
            ranges.append(NSRange(location: start, length: chars.count - start))
        }
        return ranges
    }

    /// `nil` if `actionMark` is not an underline/arrow, or if its sentence does
    /// not have a node (rectangle/circle, from any source, not hidden) both
    /// before and after it.
    static func deriveLink(for actionMark: Mark, allMarks: [Mark], cleanText: String) -> (from: String, to: String)? {
        guard actionMark.type == .underline || actionMark.type == .arrow else { return nil }
        let sentences = sentenceRanges(in: cleanText)
        guard let sentence = sentences.first(where: { NSLocationInRange(actionMark.range.start, $0) }) else { return nil }

        let nodesInSentence = allMarks
            .filter { ($0.type == .rectangle || $0.type == .circle) && !$0.hidden }
            .filter { NSLocationInRange($0.range.start, sentence) }
            .sorted { $0.range.start < $1.range.start }
        guard let before = nodesInSentence.last(where: { $0.range.start < actionMark.range.start }),
              let after = nodesInSentence.first(where: { $0.range.start > actionMark.range.start }) else { return nil }
        return (from: before.termId, to: after.termId)
    }

    /// Recomputes from scratch all the **manual** links (`source: .manual`) of
    /// a block from its current marks: simpler and more robust than an
    /// incremental update on every mark addition/removal/change (a removed
    /// mark that was a node of an existing link removes it automatically, a
    /// new node can complete one that did not exist before). `source: .claude`
    /// links (from the `links[]` of Claude's response, SPEC §7.5) are not
    /// touched.
    static func recomputeManualLinks(existingLinks: [Link], marks: [Mark], cleanText: String) -> [Link] {
        let claudeLinks = existingLinks.filter { $0.source == .claude }
        var manualLinks: [Link] = []
        var nextId = ManualMarks.nextLinkId(in: claudeLinks)
        for mark in marks.filter({ !$0.hidden }).sorted(by: { $0.range.start < $1.range.start }) {
            guard let derived = deriveLink(for: mark, allMarks: marks, cleanText: cleanText) else { continue }
            let kind: LinkKind = mark.type == .arrow ? .effect : .action
            manualLinks.append(Link(id: nextId, from: derived.from, to: derived.to, label: mark.text, kind: kind, source: .manual, via: mark.id))
            nextId = "l\((Int(nextId.dropFirst()) ?? 0) + 1)"
        }
        return claudeLinks + manualLinks
    }
}
