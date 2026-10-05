import Foundation
import Testing
@testable import LelePdf

/// `Repetitions.update` must stay IDENTICAL, not "close enough", to a full
/// recomputation (`Repetitions.compute`) after ANY sequence of marks
/// added/removed/hidden and blocks analyzed. Verified here on random
/// sequences (fixed seed, so a failure is always reproducible) of mutations
/// on real project text (the same domain sentences as
/// `RepetitionsTests`/`RepetitionsPerformanceTests`, not gibberish), not just
/// on the few hand-written cases there.
@Suite("Repetitions · incremental update matches the full recomputation")
struct RepetitionsIncrementalTests {
    /// Deterministic generator: `SystemRandomNumberGenerator` cannot be
    /// seeded, and a random test that can fail in a non-reproducible way is
    /// of no use to anyone. SplitMix64, public domain.
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Real sentences from the project's domain (adapted from `SPEC.md`),
    /// with deliberately shared vocabulary ("analisi", "documento", "segno",
    /// "ripetizione", "blocco", "termine"... as written in the Italian
    /// sentences) because `Repetitions` must find them as later occurrences;
    /// a text made of all-different words would never exercise the
    /// interesting case.
    private static let sentencePool: [String] = [
        "Il documento viene diviso in blocchi di testo prima dell'analisi.",
        "Ogni segno manuale aggiunto al blocco può cambiare la ripetizione di un termine.",
        "L'analisi di un blocco produce una riscrittura e alcuni segni veri.",
        "La ripetizione successiva dello stesso termine appare al quaranta per cento di opacità.",
        "Un termine con più segni condivide lo stesso identificativo nel documento.",
        "Il blocco più antico con un segno vero ancora il termine nel documento.",
        "Claude analizza il documento un blocco alla volta, in ordine di lettura.",
        "Un segno manuale su un blocco non ancora analizzato resta comunque visibile.",
    ]

    private func makeBlock(id: String, index: Int, text: String, textHash: String? = nil) -> TextBlock {
        TextBlock(
            id: id, sectionPath: ["Sezione"], pageStart: index, pageEnd: index, cleanText: text,
            textHash: textHash ?? id, words: text.split(separator: " ").count,
            spans: [BlockPageSpan(page: index, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
            lineRectsByPage: [:]
        )
    }

    private func sortedOccurrences(_ occ: [Repetitions.Occurrence]) -> [Repetitions.Occurrence] {
        occ.sorted { lhs, rhs in
            if lhs.blockId != rhs.blockId { return lhs.blockId < rhs.blockId }
            if lhs.termId != rhs.termId { return lhs.termId < rhs.termId }
            if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
            return lhs.range.length < rhs.range.length
        }
    }

    @Test("after every random mutation (add/remove/hide a mark, analyze a block), the incremental update matches a recomputation from scratch")
    func incrementalMatchesFullAfterRandomMutations() {
        var rng = SplitMix64(seed: 0xF6_2026_0921)
        let blockCount = 8
        let blocks = (0 ..< blockCount).map { i in
            makeBlock(
                id: "b\(i)", index: i,
                text: Self.sentencePool[i % Self.sentencePool.count] + " " + Self.sentencePool[(i + 3) % Self.sentencePool.count]
            )
        }
        let termIds = ["t0", "t1", "t2", "t3"]
        var analysis = AnalysisRecord()
        var state = Repetitions.computeFull(blocks: blocks, analysis: analysis)
        var nextMarkId = 0

        for iteration in 0 ..< 400 {
            let blockIndex = Int.random(in: 0 ..< blockCount, using: &rng)
            let blockId = "b\(blockIndex)"
            let block = blocks[blockIndex]
            let op = Int.random(in: 0 ..< 4, using: &rng)
            var current = analysis.blocks[blockId] ?? BlockAnalysis(status: .analyzed)

            switch op {
            case 0: // the block becomes (or stays) analyzed, with no new marks
                current.status = .analyzed
            case 1: // adds a real mark on a real word of the block
                let words = block.cleanText.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }.filter { $0.count >= 5 }
                guard !words.isEmpty else { continue }
                let word = words[Int.random(in: 0 ..< words.count, using: &rng)]
                guard let range = block.cleanText.range(of: word) else { continue }
                let start = block.cleanText.distance(from: block.cleanText.startIndex, to: range.lowerBound)
                let termId = termIds[Int.random(in: 0 ..< termIds.count, using: &rng)]
                nextMarkId += 1
                current.status = .analyzed
                current.marks.append(Mark(
                    id: "m\(nextMarkId)", termId: termId, type: .rectangle, text: word,
                    source: Bool.random(using: &rng) ? .manual : .claude, page: block.pageStart,
                    range: MarkRange(start: start, length: word.count)
                ))
            case 2: // removes an existing mark
                guard !current.marks.isEmpty else { continue }
                current.marks.remove(at: Int.random(in: 0 ..< current.marks.count, using: &rng))
            default: // hides/shows an existing mark (like Claude's "removed" marks, SPEC §5.7)
                guard !current.marks.isEmpty else { continue }
                let idx = Int.random(in: 0 ..< current.marks.count, using: &rng)
                current.marks[idx].hidden.toggle()
            }

            analysis.blocks[blockId] = current
            state = Repetitions.update(state: state, blocks: blocks, analysis: analysis, changedBlockIds: [blockId])
            let expected = sortedOccurrences(Repetitions.compute(blocks: blocks, analysis: analysis))
            let actual = sortedOccurrences(state.occurrences)
            #expect(actual == expected, "iteration \(iteration): the incremental update diverges from the recomputation from scratch after op \(op) on \(blockId)")
        }
    }

    /// If the set of blocks changes (resegmentation, new document), `update`
    /// has no safe base to continue incrementally from: it must fall back to
    /// `computeFull` on its own, with the SAME result: no crash, no "phantom"
    /// block in the result.
    @Test("if the set of blocks changes, the incremental update falls back to a full recomputation with the same result")
    func incrementalFallsBackToFullWhenBlockSetChanges() {
        let before = (0 ..< 4).map { i in makeBlock(id: "b\(i)", index: i, text: Self.sentencePool[i]) }
        var analysis = AnalysisRecord()
        analysis.blocks["b0"] = BlockAnalysis(status: .analyzed, marks: [
            Mark(id: "m0", termId: "t0", type: .rectangle, text: "documento", source: .claude, page: 0, range: MarkRange(start: before[0].cleanText.range(of: "documento").map { before[0].cleanText.distance(from: before[0].cleanText.startIndex, to: $0.lowerBound) } ?? 0, length: "documento".count)),
        ])
        let state = Repetitions.computeFull(blocks: before, analysis: analysis)

        // A new block appears (resegmentation): the set of blocks no longer
        // matches `state.blockIds`.
        let newBlock = makeBlock(id: "b-new", index: 4, text: "Il nuovo blocco parla anche lui del documento più avanti nel testo.")
        let after = before + [newBlock]
        analysis.blocks["b-new"] = BlockAnalysis(status: .analyzed)

        let updated = Repetitions.update(state: state, blocks: after, analysis: analysis, changedBlockIds: ["b-new"])
        let expected = sortedOccurrences(Repetitions.compute(blocks: after, analysis: analysis))
        #expect(sortedOccurrences(updated.occurrences) == expected)
        #expect(updated.blockIds == Set(after.map(\.id)))
    }

    /// `TextBlock.id` is a hash of section + FIRST 60 characters + page
    /// (`BlockSegmenter.makeId`): a resegmentation can keep the same id with a
    /// different text tail. The incremental state keeps the `Haystack` and the
    /// occurrences per id: if the text under the same id changes, `update`
    /// MUST notice (from the `textHash`) and fall back to the full
    /// recomputation; otherwise it would return occurrences of a text that no
    /// longer exists.
    @Test("same id but different text (textHash changed): the incremental update falls back to the full recomputation")
    func incrementalFallsBackWhenTextChangesUnderSameId() {
        // Three sentences that all contain "documento": anchor in b0, one
        // repetition each in b1 and b2.
        let texts = [Self.sentencePool[0], Self.sentencePool[4], Self.sentencePool[5]]
        let before = texts.enumerated().map { i, text in makeBlock(id: "b\(i)", index: i, text: text) }
        var analysis = AnalysisRecord()
        let docRange = before[0].cleanText.range(of: "documento")!
        let docStart = before[0].cleanText.distance(from: before[0].cleanText.startIndex, to: docRange.lowerBound)
        analysis.blocks["b0"] = BlockAnalysis(status: .analyzed, marks: [
            Mark(id: "m0", termId: "t0", type: .rectangle, text: "documento", source: .claude, page: 0, range: MarkRange(start: docStart, length: "documento".count)),
        ])
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed)
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed)
        let state = Repetitions.computeFull(blocks: before, analysis: analysis)
        #expect(state.occurrences.count == 2) // "documento" really occurs in b1 and b2

        // Same id "b2", same beginning (hence same `makeId`), different tail:
        // `textHash` changes. The declared mutation concerns ANOTHER block
        // (b1), so the only way to notice the new text in b2 is the
        // `textHash` guard, not `changedBlockIds`.
        var after = before
        after[2] = makeBlock(id: "b2", index: 2, text: texts[2] + " E qui il documento è citato ancora due volte: documento.", textHash: "diverso")

        let updated = Repetitions.update(state: state, blocks: after, analysis: analysis, changedBlockIds: ["b1"])
        let expected = sortedOccurrences(Repetitions.compute(blocks: after, analysis: analysis))
        #expect(sortedOccurrences(updated.occurrences) == expected)
        #expect(updated.occurrences.count == 4) // the two new citations in the tail of b2 were found
    }

    /// `firstBlockIndex` and "block after the anchor" are INDEXES in document
    /// order: the same ids in a different order are not the same document, and
    /// the incremental update must fall back to the full recomputation.
    @Test("same ids in a different order: the incremental update falls back to the full recomputation")
    func incrementalFallsBackWhenOrderChanges() {
        // b0 contains "blocchi" (does NOT match "blocco" at a word boundary),
        // b1 and b2 contain "blocco": anchor in the MIDDLE block. Before
        // reordering, b2 is "after" the anchor (1 repetition); after the swap
        // it is b0 that is "after", and "blocco" is not there (0
        // repetitions). Without the fallback, the stale occurrence in b2 would
        // stay in the result.
        let before = (0 ..< 3).map { i in makeBlock(id: "b\(i)", index: i, text: Self.sentencePool[i]) }
        var analysis = AnalysisRecord()
        let wordRange = before[1].cleanText.range(of: "blocco")!
        let wordStart = before[1].cleanText.distance(from: before[1].cleanText.startIndex, to: wordRange.lowerBound)
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [
            Mark(id: "m0", termId: "t0", type: .rectangle, text: "blocco", source: .claude, page: 1, range: MarkRange(start: wordStart, length: "blocco".count)),
        ])
        analysis.blocks["b0"] = BlockAnalysis(status: .analyzed)
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed)
        let state = Repetitions.computeFull(blocks: before, analysis: analysis)
        #expect(state.occurrences.count == 1)
        #expect(state.occurrences.first?.blockId == "b2")

        let reordered = [before[2], before[1], before[0]]
        let updated = Repetitions.update(state: state, blocks: reordered, analysis: analysis, changedBlockIds: [])
        let expected = sortedOccurrences(Repetitions.compute(blocks: reordered, analysis: analysis))
        #expect(sortedOccurrences(updated.occurrences) == expected)
        #expect(updated.occurrences.isEmpty)
        #expect(updated.blockOrder == reordered.map(\.id))
    }
}
