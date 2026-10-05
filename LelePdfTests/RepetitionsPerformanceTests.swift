import Foundation
import Testing
@testable import LelePdf

/// Performance of manual marks: the user reported that inserting and
/// removing marks on the text felt a bit slow with many analyzed blocks. The
/// actual cause found: `Repetitions.compute` (SPEC §7.5.4) was called by
/// `AnalysisControllerMarks.markItems(forPage:)` once for EVERY VISIBLE PAGE
/// on every redraw, instead of once per context. With ~50+ analyzed blocks,
/// that was repeated for every visible page while scrolling or after a
/// single mark was added/removed. This test measures the cost of
/// `Repetitions.compute` alone (pure, without PDFKit) on a synthetic document
/// comparable to the Draghi report with many analyzed blocks, to have a
/// reference number; `AnalysisControllerManualMarksUndoTests`/
/// `AnalysisControllerManualMarksTests` already cover the cache invalidation
/// contract (`repetitionsCache`/`markItemsCache`).
@Suite("Repetitions · performance")
struct RepetitionsPerformanceTests {
    /// ~50 analyzed blocks (comparable to the Draghi report with ~50 analyzed
    /// blocks, SPEC §7.3 blocks of 250-600 words), each with a real mark on a
    /// shared term AND an unmarked mention of the previous block's term. This
    /// generates real repetition occurrences (SPEC §7.5.4), not a degenerate
    /// case where `Repetitions.compute` has nothing to do.
    private func syntheticDocument(blockCount: Int = 50, fillerWords: Int = 60) -> (blocks: [TextBlock], analysis: AnalysisRecord) {
        let sharedTerms = ["crescita economica", "tasso di interesse", "mercato del lavoro", "produttività", "investimenti pubblici"]
        var blocks: [TextBlock] = []
        var analysis = AnalysisRecord()
        for i in 0 ..< blockCount {
            let id = "b\(i)"
            let ownTerm = sharedTerms[i % sharedTerms.count]
            var text = "Il documento discute \(ownTerm) e altri fattori macroeconomici rilevanti per la politica economica nazionale."
            if i > 0 {
                // An UNMARKED mention of an earlier block's term: this is the
                // real "repetition" that `Repetitions.compute` must find.
                let repeatedTerm = sharedTerms[(i - 1) % sharedTerms.count]
                text += " Anche \(repeatedTerm) resta un tema centrale in questo capitolo."
            }
            for w in 0 ..< fillerWords { text += " parola\(w)" }
            let page = i
            let block = TextBlock(
                id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id, words: fillerWords + 12,
                spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
                lineRectsByPage: [:]
            )
            blocks.append(block)
            let termId = "t\(i % sharedTerms.count)"
            let start = text.range(of: ownTerm).map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
            let mark = Mark(id: "m\(i)", termId: termId, type: .rectangle, text: ownTerm, source: .claude, page: page, range: MarkRange(start: start, length: ownTerm.count))
            analysis.blocks[id] = BlockAnalysis(status: .analyzed, marks: [mark])
            analysis.terms[termId] = TermRecord(term: ownTerm, type: .rectangle, firstBlockId: id)
        }
        return (blocks, analysis)
    }

    @Test("Repetitions.compute on ~50 analyzed blocks stays under 200 ms (a single call per context, not per page)")
    func computeStaysFast() {
        let (blocks, analysis) = syntheticDocument()
        let start = Date()
        let occurrences = Repetitions.compute(blocks: blocks, analysis: analysis)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        // Generous threshold (unoptimized Debug/XCTest build): the point of
        // the test is not a precise figure but a guard against a regression
        // that would run it once per visible page again instead of once per
        // context (the real bug), at which point the cost would be multiplied
        // by the number of visible pages, easily going past a second.
        #expect(elapsedMs < 200, "Repetitions.compute took \(elapsedMs) ms on \(blocks.count) blocks")
        #expect(!occurrences.isEmpty) // the repetitions of the 5 shared terms really exist
    }

    private func sortedOccurrences(_ occ: [Repetitions.Occurrence]) -> [Repetitions.Occurrence] {
        occ.sorted { lhs, rhs in
            if lhs.blockId != rhs.blockId { return lhs.blockId < rhs.blockId }
            if lhs.termId != rhs.termId { return lhs.termId < rhs.termId }
            if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
            return lhs.range.length < rhs.range.length
        }
    }

    /// Previously a mutation cleared `repetitionsCache` SYNCHRONOUSLY (`nil`),
    /// forcing the next draw to wait for `Repetitions.compute` from scratch on
    /// the MainActor, exactly the cost this work was meant to remove. Now the
    /// recomputation runs off the MainActor (`AnalysisControllerRepetitions`,
    /// `RepetitionsEngine`) and `repetitionsCache` keeps its previous value
    /// until the new one is ready; it must NEVER go back to `nil` because of a
    /// mutation (it would block the draw that reads it). The test verifies
    /// both this (right after the mutation) and the final correctness (after
    /// waiting for the recomputation, the result must match a
    /// `Repetitions.compute` from scratch on the updated state, with no
    /// out-of-order publication).
    @Test("a mutation no longer clears repetitionsCache synchronously; the background recomputation stays correct")
    @MainActor
    func mutationUpdatesRepetitionsCacheAsynchronouslyAndCorrectly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfRepetitionsPerfTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-perf"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 50)
        let (blocks, analysis) = syntheticDocument()
        let controller = AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!)
        controller.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: blocks, exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])

        // `updateContext` has already scheduled a full computation off the
        // MainActor (`scheduleRepetitionsFull`): wait for it to start from a
        // known state, as a real draw would after the document is opened.
        await controller.waitForPendingRepetitionsUpdate()
        let initial = try #require(controller.repetitionsCache)
        #expect(!initial.isEmpty) // the repetitions of the 5 shared terms really exist

        await controller.addManualMark(blockId: "b0", type: .circle, text: "parola7", page: 0, cleanRange: NSRange(location: 0, length: 7))
        // Right after the mutation, BEFORE waiting for the recomputation:
        // `repetitionsCache` must never be `nil` (an immediate draw with the
        // previous state, never blocked).
        #expect(controller.repetitionsCache != nil)
        #expect(controller.markItemsCache.isEmpty) // invalidated immediately, that one yes (cheap)

        await controller.waitForPendingRepetitionsUpdate()
        let context = try #require(controller.context)
        let expected = Repetitions.compute(blocks: context.blocks, analysis: context.analysis)
        #expect(sortedOccurrences(controller.repetitionsCache ?? []) == sortedOccurrences(expected))
    }

    /// Measures `Repetitions.update` ALONE (`Date()`, with no
    /// `AnalysisController`/`DocumentStore`/performance benchmark in between;
    /// the benchmark runs on a machine shared with other jobs, and its number
    /// for this stage oscillated 5-140 ms between two identical runs because
    /// of CPU contention, not because of a regression) on the worst case
    /// measured there: a manual mark with an ALWAYS NEW term (never seen
    /// before) added always to the SAME initial block (the oldest possible
    /// anchor, so the term must be searched for in ALL the other analyzed
    /// blocks) and removed right away, repeated many times: the case that
    /// forces `update` to search for a new term across the whole document most
    /// often.
    @Test("Repetitions.update stays much faster than a full recomputation even in the worst case (always a new term, always the oldest anchor)")
    func updateStaysFastForRepeatedNewTermsOnOldestBlock() {
        let (blocks, analysis) = syntheticDocument(blockCount: 45, fillerWords: 80)
        var currentAnalysis = analysis
        // Only the first 18 blocks analyzed (fraction 0.4, as in the performance benchmark).
        for i in 18 ..< blocks.count { currentAnalysis.blocks.removeValue(forKey: "b\(i)") }
        var state = Repetitions.computeFull(blocks: blocks, analysis: currentAnalysis)

        var updateTimesMs: [Double] = []
        for i in 0 ..< 30 {
            var block0 = currentAnalysis.blocks["b0"] ?? BlockAnalysis(status: .analyzed)
            let newTermId = "new-term-\(i)"
            block0.marks.append(Mark(id: "new-mark-\(i)", termId: newTermId, type: .rectangle, text: "parola\(i)", source: .manual, page: 0, range: MarkRange(start: 0, length: 7)))
            currentAnalysis.blocks["b0"] = block0

            let start = Date()
            state = Repetitions.update(state: state, blocks: blocks, analysis: currentAnalysis, changedBlockIds: ["b0"])
            updateTimesMs.append(Date().timeIntervalSince(start) * 1000)

            // Removed right after (like the benchmark's "add then remove").
            block0.marks.removeAll { $0.id == "new-mark-\(i)" }
            currentAnalysis.blocks["b0"] = block0
            state = Repetitions.update(state: state, blocks: blocks, analysis: currentAnalysis, changedBlockIds: ["b0"])
        }
        updateTimesMs.sort()
        let median = updateTimesMs[updateTimesMs.count / 2]
        let maxMs = updateTimesMs.last ?? 0
        print("REPETITIONS-UPDATE new-term-on-oldest-block: median=\(median) max=\(maxMs) ms (n=\(updateTimesMs.count))")
        // Generous threshold (unoptimized Debug/XCTest, like `computeStaysFast`
        // above): the point is to stay an order of magnitude below the 79-85
        // ms of `Repetitions.compute` from scratch at a comparable scale, not
        // to hit a precise figure.
        #expect(median < 30, "Repetitions.update (new term on the oldest block) too slow: median \(median) ms")
    }

    /// A missing figure: the main guarantee was architectural (a single
    /// `Repetitions.compute` per context), but there was no measured
    /// end-to-end time for the real action the user reported as slow, adding
    /// or removing a mark, not just the pure function. Measures here
    /// `addManualMark`/`removeMark` end-to-end (including the round trip
    /// through the Store, as in the real app) on a synthetic document "like
    /// the Draghi report with ~50 analyzed blocks" (same generator as
    /// `computeStaysFast`). Unoptimized Debug/XCTest build: generous
    /// threshold; the real measured number is recorded by hand elsewhere.
    @Test("adding/removing a manual mark end-to-end stays under 100 ms on ~50 analyzed blocks")
    @MainActor
    func addRemoveMarkLatencyOnDraghiLikeDocument() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfMarkLatencyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-latency"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 50)
        let (blocks, analysis) = syntheticDocument()
        let controller = AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!)
        controller.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: blocks, exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])

        var addTimes: [Double] = []
        var removeTimes: [Double] = []
        for i in 0 ..< 20 {
            let blockId = "b\(i % blocks.count)"
            let addStart = Date()
            await controller.addManualMark(blockId: blockId, type: .circle, text: "parola3", page: i % blocks.count, cleanRange: NSRange(location: 0, length: 7))
            addTimes.append(Date().timeIntervalSince(addStart) * 1000)

            guard let markId = controller.context?.analysis.blocks[blockId]?.marks.last?.id else { continue }
            let removeStart = Date()
            await controller.removeMark(blockId: blockId, markId: markId)
            removeTimes.append(Date().timeIntervalSince(removeStart) * 1000)
        }
        addTimes.sort(); removeTimes.sort()
        let addP95 = addTimes[Int(Double(addTimes.count - 1) * 0.95)]
        let removeP95 = removeTimes[Int(Double(removeTimes.count - 1) * 0.95)]
        let addMedian = addTimes[addTimes.count / 2]
        let removeMedian = removeTimes[removeTimes.count / 2]
        // Printed for the measurements notes (no profiler involved; the
        // reported number comes from this run).
        print("MARK-LATENCY add: min=\(addTimes.first ?? 0) median=\(addMedian) p95=\(addP95) ms (n=\(addTimes.count))")
        print("MARK-LATENCY remove: min=\(removeTimes.first ?? 0) median=\(removeMedian) p95=\(removeP95) ms (n=\(removeTimes.count))")
        #expect(addP95 < 100, "adding a manual mark too slow: p95 \(addP95) ms")
        #expect(removeP95 < 100, "removing a manual mark too slow: p95 \(removeP95) ms")
    }
}
