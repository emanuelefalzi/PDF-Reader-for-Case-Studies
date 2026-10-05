import Foundation

/// Incremental computation of repetitions: a separate file from
/// `Repetitions.swift` to keep files small, same type.
///
/// `Repetitions.compute` used to be redone FROM SCRATCH (all blocks for all
/// terms) on every mark added/removed and every analysis that arrived (79-511
/// ms measured by the performance benchmark, depending on how many blocks were
/// already analyzed). `computeFull`/`update` below produce the SAME result as
/// `Repetitions.compute`, but `update` only touches:
/// (a) the occurrences INSIDE the block that just changed, for every term (its
///     text/real-mark coverage may have changed, and this also concerns terms
///     whose mark did not move: a new real mark in that block covers portions
///     of text that before could count as a repetition of ANOTHER term);
/// (b) every term whose set of texts (`markTexts`) or whose first-real-mark
///     block (`firstBlockIndex`) changed, in ALL blocks, not just the touched
///     one: if a term's first real mark moves (added earlier, or removed where
///     it was the only one), the set of blocks "after" that mark in which to
///     search changes.
///
/// **`haystackByBlock`**: measured after the first version of this file, case
/// (b) ("a NEW term with an old anchor, searched in many untouched blocks")
/// cost almost as much as `Repetitions.compute` from scratch. Not because of
/// the search itself, but because `Haystack(block.cleanText)` (`[Character]` +
/// lowercase) was rebuilt on every call for EVERY block touched by the search,
/// even when that block's TEXT had not changed at all (only its marks change,
/// never `TextBlock.cleanText`, for a mutation going through `update`; a real
/// text change is a resegmentation, which changes the set of blocks and falls
/// back to `computeFull` below anyway). Each block's `Haystack` is therefore
/// built at most ONCE over the whole life of a state (`RepetitionsEngine`) and
/// reused by every subsequent `update`, even when the search touches blocks
/// never touched by a mutation before.
///
/// If the set of blocks no longer matches the last known state (structure
/// changed: resegmentation, new document), `update` falls back to
/// `computeFull` by itself: always correct, never a crash or an inconsistent
/// result for an unforeseen case.
extension Repetitions {
    /// State between one call and the next (`RepetitionsEngine`, off the
    /// MainActor): the per-term aggregate (`markTexts`/`firstBlockIndex`, cheap
    /// to rebuild entirely, since it depends only on the NUMBER of marks, not
    /// on the length of the texts), the occurrences already found (by block and
    /// by term, so a single block/term can be replaced without touching the
    /// others) and the ready-made `Haystack` of every block touched so far.
    struct IncrementalState: Sendable {
        // Not `fileprivate`: `RepetitionsEngine.swift` (same module, different
        // file) and the tests (`@testable import`, which only elevates
        // `internal`, not `fileprivate`) read `blockIds`/`occurrences`.
        /// Ids of the blocks IN DOCUMENT ORDER and, in parallel, the
        /// `TextBlock.textHash` of each. `update` falls back to `computeFull` if
        /// either does not match: the order matters (`firstBlockIndex` and the
        /// "block after the anchor" comparison are indices in this order) and
        /// so does the text (`TextBlock.id` is a hash of section + FIRST 60
        /// characters + page, `BlockSegmenter.makeId`: a resegmentation can
        /// keep the same id with a different text tail, and then the cached
        /// `Haystack` and the occurrences already found would be stale).
        var blockOrder: [String]
        var textHashes: [String]
        var markTexts: [String: Set<String>]
        var firstBlockIndex: [String: Int]
        var occurrencesByBlockAndTerm: [String: [String: [Occurrence]]]
        var haystackByBlock: [String: Haystack]

        var blockIds: Set<String> { Set(blockOrder) }

        var occurrences: [Occurrence] {
            occurrencesByBlockAndTerm.values.flatMap { $0.values.flatMap { $0 } }
        }

        static let empty = IncrementalState(blockOrder: [], textHashes: [], markTexts: [:], firstBlockIndex: [:], occurrencesByBlockAndTerm: [:], haystackByBlock: [:])

        /// True if `blocks` are the SAME blocks (id, order and text) from which
        /// this state was computed: only then can `update` restart from here
        /// instead of redoing everything.
        func matchesStructure(of blocks: [TextBlock]) -> Bool {
            guard blocks.count == blockOrder.count else { return false }
            for (index, block) in blocks.enumerated() where block.id != blockOrder[index] || block.textHash != textHashes[index] {
                return false
            }
            return true
        }
    }

    /// The same algorithm as ever (see `Repetitions.swift`), rewritten to also
    /// keep the per-term aggregate, the occurrences by block/term and the
    /// `Haystack`s that `update` needs in order to restart.
    static func computeFull(blocks: [TextBlock], analysis: AnalysisRecord) -> IncrementalState {
        let order = blocks.map(\.id)
        let orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let (markTexts, firstBlockIndex) = markTextsAndFirstIndex(order: order, orderIndex: orderIndex, analysis: analysis)

        let textHashes = blocks.map(\.textHash)
        guard !markTexts.isEmpty else {
            return IncrementalState(blockOrder: order, textHashes: textHashes, markTexts: [:], firstBlockIndex: [:], occurrencesByBlockAndTerm: [:], haystackByBlock: [:])
        }

        var occurrencesByBlockAndTerm: [String: [String: [Occurrence]]] = [:]
        var haystackByBlock: [String: Haystack] = [:]
        for block in blocks {
            guard let blockAnalysis = analysis.blocks[block.id], blockAnalysis.status == .analyzed else { continue }
            let blockIndex = orderIndex[block.id] ?? Int.max
            let termsToScan = markTexts.keys.filter { (firstBlockIndex[$0] ?? Int.max) < blockIndex }
            guard !termsToScan.isEmpty else { continue }
            let haystack = Haystack(block.cleanText)
            haystackByBlock[block.id] = haystack
            let perTerm = occurrencesForBlock(block, haystack: haystack, blockAnalysis: blockAnalysis, terms: termsToScan, markTexts: markTexts)
            if !perTerm.isEmpty { occurrencesByBlockAndTerm[block.id] = perTerm }
        }
        return IncrementalState(blockOrder: order, textHashes: textHashes, markTexts: markTexts, firstBlockIndex: firstBlockIndex, occurrencesByBlockAndTerm: occurrencesByBlockAndTerm, haystackByBlock: haystackByBlock)
    }

    /// Incremental update: `state` must come from a previous
    /// `computeFull`/`update` on the SAME set of blocks (ids, not content: the
    /// content is exactly what may have changed). `changedBlockIds` are the
    /// blocks whose `BlockAnalysis` (marks and/or status) changed since the
    /// last known state.
    static func update(
        state: IncrementalState,
        blocks: [TextBlock],
        analysis: AnalysisRecord,
        changedBlockIds: Set<String>
    ) -> IncrementalState {
        let order = blocks.map(\.id)
        guard state.matchesStructure(of: blocks) else {
            // Structure changed (block added/removed/moved, or different text
            // under the same id): no safe base to start incrementally from, so
            // everything is recomputed: always correct, never an out-of-range
            // array or a ghost block in the result.
            return computeFull(blocks: blocks, analysis: analysis)
        }
        let orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let blocksById = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let (markTexts, firstBlockIndex) = markTextsAndFirstIndex(order: order, orderIndex: orderIndex, analysis: analysis)

        guard !markTexts.isEmpty else {
            return IncrementalState(blockOrder: state.blockOrder, textHashes: state.textHashes, markTexts: [:], firstBlockIndex: [:], occurrencesByBlockAndTerm: [:], haystackByBlock: state.haystackByBlock)
        }

        // Terms whose set of texts or whose anchor (`firstBlockIndex`) changed
        // compared to the previous state: they must be searched in EVERY block
        // after the new anchor, not just the touched block (point (b) above).
        var affectedTerms: Set<String> = []
        for term in Set(markTexts.keys).union(state.markTexts.keys) {
            if markTexts[term] != state.markTexts[term] || firstBlockIndex[term] != state.firstBlockIndex[term] {
                affectedTerms.insert(term)
            }
        }

        var occurrencesByBlockAndTerm = state.occurrencesByBlockAndTerm
        var haystackByBlock = state.haystackByBlock
        for blockId in changedBlockIds { occurrencesByBlockAndTerm.removeValue(forKey: blockId) }
        if !affectedTerms.isEmpty {
            for blockId in occurrencesByBlockAndTerm.keys {
                for term in affectedTerms { occurrencesByBlockAndTerm[blockId]?.removeValue(forKey: term) }
            }
        }

        for blockId in order {
            guard let block = blocksById[blockId],
                  let blockAnalysis = analysis.blocks[blockId], blockAnalysis.status == .analyzed else { continue }
            let blockIndex = orderIndex[blockId] ?? Int.max
            // The touched block must be re-read for EVERY term (point (a)
            // above: its real-mark coverage may have changed even for terms
            // whose mark did not move); an untouched block only for the
            // "affected" terms.
            let candidateTerms: Set<String> = changedBlockIds.contains(blockId) ? Set(markTexts.keys) : affectedTerms
            let termsToScan = candidateTerms.filter { (firstBlockIndex[$0] ?? Int.max) < blockIndex }
            guard !termsToScan.isEmpty else { continue }

            // The block's TEXT (`cleanText`) never changes for a mutation that
            // arrives here (only its marks): the already computed `Haystack`
            // stays valid, and is rebuilt only the first time this block is
            // touched by a search.
            let haystack: Haystack
            if let cached = haystackByBlock[blockId] {
                haystack = cached
            } else {
                haystack = Haystack(block.cleanText)
                haystackByBlock[blockId] = haystack
            }

            let perTerm = occurrencesForBlock(block, haystack: haystack, blockAnalysis: blockAnalysis, terms: Array(termsToScan), markTexts: markTexts)
            for termId in termsToScan {
                if let occ = perTerm[termId] {
                    occurrencesByBlockAndTerm[blockId, default: [:]][termId] = occ
                } else {
                    occurrencesByBlockAndTerm[blockId]?.removeValue(forKey: termId)
                }
            }
        }

        return IncrementalState(blockOrder: state.blockOrder, textHashes: state.textHashes, markTexts: markTexts, firstBlockIndex: firstBlockIndex, occurrencesByBlockAndTerm: occurrencesByBlockAndTerm, haystackByBlock: haystackByBlock)
    }

    /// The per-term aggregate (SPEC leaves room on "term text"; the choice is
    /// the union of the marks' exact texts). Only O(number of marks), never the
    /// expensive part (scanning the blocks' text), so it is rebuilt entirely on
    /// every call even inside `update`, rather than keeping a delta that is
    /// harder to keep in sync with the previous state.
    private static func markTextsAndFirstIndex(
        order: [String], orderIndex: [String: Int], analysis: AnalysisRecord
    ) -> (markTexts: [String: Set<String>], firstBlockIndex: [String: Int]) {
        var markTexts: [String: Set<String>] = [:]
        var firstBlockIndex: [String: Int] = [:]
        for blockId in order {
            guard let blockAnalysis = analysis.blocks[blockId], blockAnalysis.status == .analyzed else { continue }
            let blockIndex = orderIndex[blockId] ?? Int.max
            for mark in blockAnalysis.marks where !mark.hidden {
                markTexts[mark.termId, default: []].insert(mark.text)
                let existing = firstBlockIndex[mark.termId]
                if existing == nil || blockIndex < existing! {
                    firstBlockIndex[mark.termId] = blockIndex
                }
            }
        }
        return (markTexts, firstBlockIndex)
    }

    /// Occurrences of `terms` inside ONE block (the same search as
    /// `Repetitions.compute`, isolated here because both `computeFull` and
    /// `update` call it on a single block at a time). `haystack` arrives ready
    /// from the caller (new or from the cache), never rebuilt here: see the
    /// comment on `IncrementalState.haystackByBlock`.
    private static func occurrencesForBlock(
        _ block: TextBlock, haystack: Haystack, blockAnalysis: BlockAnalysis, terms: [String], markTexts: [String: Set<String>]
    ) -> [String: [Occurrence]] {
        let coveredRanges = blockAnalysis.marks
            .filter { !$0.hidden }
            .map { NSRange(location: $0.range.start, length: $0.range.length) }
        var result: [String: [Occurrence]] = [:]
        for termId in terms {
            guard let texts = markTexts[termId] else { continue }
            var occ: [Occurrence] = []
            for text in texts {
                for range in wordBoundaryOccurrences(of: text, in: haystack) {
                    guard !coveredRanges.contains(where: { intersects($0, range) }) else { continue }
                    occ.append(Occurrence(blockId: block.id, termId: termId, range: range))
                }
            }
            if !occ.isEmpty { result[termId] = occ }
        }
        return result
    }
}
