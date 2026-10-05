import Foundation

/// Scheduling of repetition recomputations off the MainActor: a separate file
/// to keep files small, like the other extensions of `AnalysisController`. The
/// mutable properties (`repetitionsEngine`, `repetitionsTask`, the two
/// sequence counters) stay declared in `AnalysisController.swift`, since an
/// extension cannot add stored instance properties to a class.
@MainActor
extension AnalysisController {
    private enum RepetitionsUpdateKind {
        case full
        case incremental(String)
    }

    /// To be called when structure/analysis change wholesale
    /// (`updateContext`): there is no single block to isolate, so everything
    /// is recomputed, but off the MainActor and chained after any computation
    /// already in progress.
    func scheduleRepetitionsFull() {
        scheduleRepetitions(.full)
    }

    /// To be called when a single block has changed (manual mark
    /// added/changed/removed, analysis arrived/regenerated):
    /// `Repetitions.update` recomputes only that block and the terms whose
    /// first real mark moved because of it (`RepetitionsIncremental.swift`).
    func scheduleRepetitionsIncremental(changedBlockId: String) {
        scheduleRepetitions(.incremental(changedBlockId))
    }

    /// Tests only: waits for ALL the already-chained repetition computations to
    /// have published their result, so `repetitionsCache` is guaranteed to be
    /// the final one rather than an intermediate one. Same pattern as
    /// `waitForPendingManualMarkPersistence()`.
    func waitForPendingRepetitionsUpdate() async {
        await repetitionsTask?.value
    }

    private func scheduleRepetitions(_ kind: RepetitionsUpdateKind) {
        guard let context else { return }
        repetitionsRequestSeq += 1
        let seq = repetitionsRequestSeq
        let blocks = context.blocks
        let analysis = context.analysis
        let engine = repetitionsEngine
        // Chained to the previous computation (same pattern as
        // `manualMarksPersistenceTask` in `AnalysisControllerManualMarks.
        // enqueuePersistence`): it waits for that one to have FINISHED
        // publishing its result before starting, so two close requests (for
        // example a mark removed right after one was added) can never publish
        // out of order.
        let predecessor = repetitionsTask
        repetitionsTask = Task { [weak self] in
            await predecessor?.value
            let start = CFAbsoluteTimeGetCurrent()
            let occurrences: [Repetitions.Occurrence]
            switch kind {
            case .full:
                occurrences = await engine.full(blocks: blocks, analysis: analysis)
            case .incremental(let changedBlockId):
                occurrences = await engine.incremental(blocks: blocks, analysis: analysis, changedBlockId: changedBlockId)
            }
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            guard let self else { return }
            self.applyRepetitions(seq: seq, occurrences: occurrences, elapsedMs: elapsedMs)
        }
    }

    /// Publishes the result ONLY if `seq` is still the most recent one applied
    /// ("an old result can never overwrite a newer one"): a safety net on top
    /// of the chaining above, which already guarantees the ordering by itself
    /// as long as it stays in place. Redraws only if the result has REALLY
    /// changed: not every recomputation (for example a mark that changed type,
    /// which does not touch the text) moves the repetitions.
    ///
    /// `elapsedMs` (wall-clock time of the computation, measured around the
    /// `await` on `repetitionsEngine`: predecessor wait excluded, actor hop
    /// included) is recorded under a NEW label (`marks.repetitions.background`)
    /// and no longer under `marks.repetitions.compute`: in the per-stage table
    /// of the performance benchmark that column reads as main-thread time, and
    /// this is not. The main-thread cost of the recomputation is now only this
    /// method (comparison and publication), and the benchmark sees it where it
    /// should: in `PerfBenchStallMeter` and in the action's wall-clock time.
    private func applyRepetitions(seq: Int, occurrences: [Repetitions.Occurrence], elapsedMs: Double) {
        PerfProbe.record("marks.repetitions.background", elapsedMs: elapsedMs)
        guard seq > repetitionsAppliedSeq else { return }
        repetitionsAppliedSeq = seq
        guard repetitionsCache != occurrences else { return }
        repetitionsCache = occurrences
        markItemsCache.removeAll()
        onRepetitionsUpdated?()
    }
}
