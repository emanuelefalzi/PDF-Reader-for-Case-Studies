import Foundation
import os

/// Post-processing orchestrator (SPEC §7.5 "Post-processing", points
/// 1-2-3-5): from the raw response, already decoded and validated against the
/// schema (by `BatchRunner`), to `Mark`/`Link`/`rewrite` ready for
/// `DocumentStore.updateAnalysis`. Pure (no I/O, no actors):
/// `TextBlock.resolve(cleanRange:)` does not require PDFKit.
enum AnalysisPostProcessor {
    private static let logger = Logger(subsystem: "com.emanuele.LelePdf", category: "Analysis")

    struct Input: Sendable {
        var response: AnalysisResponseRaw
        var block: TextBlock
        /// Term registry BEFORE this block (SPEC §7.5 point 1).
        var existingTerms: [String: TermRecord]
    }

    struct Output: Sendable {
        var title: String
        var rewrite: [RewriteItem]
        var marks: [Mark]
        var links: [Link]
        /// Only the new entries minted by this block: the caller merges them
        /// into the existing registry before saving.
        var newTerms: [String: TermRecord]
        var droppedMarkCount: Int
        var totalMarkCount: Int
    }

    static func process(_ input: Input) -> Output {
        let block = input.block
        var terms = input.existingTerms
        var newTerms: [String: TermRecord] = [:]
        var keptMarkTermIds: [String: String] = [:] // raw mark id -> termId
        var marks: [Mark] = []
        var droppedCount = 0
        var consumedEnd: [String: Int] = [:] // mark text -> next search point
        let cleanChars = Array(block.cleanText)

        for raw in input.response.marks {
            let trimmedText = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                droppedCount += 1
                logger.log("Mark \(raw.id, privacy: .public) dropped: empty text (block \(block.id, privacy: .public))")
                continue
            }

            let searchStart = consumedEnd[raw.text] ?? 0
            guard let matched = MarkMatcher.match(text: raw.text, in: cleanChars, after: searchStart) else {
                droppedCount += 1
                logger.log("Mark \(raw.id, privacy: .public) dropped: no match in block \(block.id, privacy: .public)")
                continue
            }
            consumedEnd[raw.text] = matched.range.location + matched.range.length

            guard let firstPage = block.resolve(cleanRange: matched.range).first else {
                droppedCount += 1
                logger.log("Mark \(raw.id, privacy: .public) dropped: range cannot be resolved to a page (block \(block.id, privacy: .public))")
                continue
            }

            let resolution = TermRegistry.resolve(term: raw.term, proposedTermId: raw.termId, in: terms)
            if resolution.isNew {
                let record = TermRecord(term: raw.term, type: raw.mark, firstBlockId: block.id)
                terms[resolution.termId] = record
                newTerms[resolution.termId] = record
            }

            keptMarkTermIds[raw.id] = resolution.termId
            marks.append(Mark(
                id: raw.id, termId: resolution.termId, type: raw.mark, text: raw.text,
                source: .claude, page: firstPage.page,
                range: MarkRange(start: matched.range.location, length: matched.range.length)
            ))
        }

        let keptIds = Set(keptMarkTermIds.keys)
        let sanitizedRewrite = input.response.rewrite
            .map(TableTruncation.truncate)
            .map(BulletSubItemsNormalizer.align)
            .map(OutlineLinesNormalizer.align)
            .map { MarkerSanitizer.sanitize($0, keptMarkIds: keptIds) }

        var links: [Link] = []
        for (index, raw) in input.response.links.enumerated() {
            guard let from = resolveLinkEndpoint(raw.from, keptMarkTermIds: keptMarkTermIds, terms: terms),
                  let to = resolveLinkEndpoint(raw.to, keptMarkTermIds: keptMarkTermIds, terms: terms) else {
                continue // an endpoint does not resolve: the whole link is dropped
            }
            let via = raw.via.flatMap { keptMarkTermIds[$0] != nil ? $0 : nil }
            links.append(Link(id: "\(block.id)-l\(index)", from: from, to: to, label: raw.label, kind: raw.kind, source: .claude, via: via))
        }

        return Output(
            title: input.response.title, rewrite: sanitizedRewrite, marks: marks, links: links,
            newTerms: newTerms, droppedMarkCount: droppedCount, totalMarkCount: input.response.marks.count
        )
    }

    /// `from`/`to`/`via` are a mark id or a `termId` (SPEC §7.5 point 13): a
    /// matched mark id resolves to that mark's `termId`; an already known
    /// `termId` (registry after this block) stays as it is; anything else does
    /// not resolve.
    private static func resolveLinkEndpoint(_ ref: String, keptMarkTermIds: [String: String], terms: [String: TermRecord]) -> String? {
        if let termId = keptMarkTermIds[ref] { return termId }
        if terms[ref] != nil { return ref }
        return nil
    }
}
