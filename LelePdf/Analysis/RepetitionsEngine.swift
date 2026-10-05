import Foundation

/// Repetitions off the MainActor. `Repetitions.compute`/`update` are pure (no
/// PDFKit), but as long as the only caller was
/// `AnalysisControllerMarks.cachedRepetitions` they still ran on the main
/// thread, taking 79-511 ms on every mark added/removed or analysis that
/// arrived. This actor owns the only mutable state
/// (`Repetitions.IncrementalState`) and updates it serially, on a thread of
/// the cooperative pool, never the main one.
///
/// The order of publication to the MainActor (never an old result over a new
/// one) is NOT this actor's job: it is guaranteed by the caller
/// (`AnalysisController.scheduleRepetitions`, in
/// `AnalysisControllerRepetitions.swift`) by chaining each request to the
/// completion of the previous one, as
/// `AnalysisControllerManualMarks.enqueuePersistence` already does for
/// persistence.
actor RepetitionsEngine {
    private var state: Repetitions.IncrementalState?

    /// Full recomputation: used on context change (`updateContext`, structure
    /// and analysis replaced wholesale) and as the automatic fallback of
    /// `incremental(...)` when the set of blocks no longer matches the last
    /// known state (see `Repetitions.update`).
    ///
    /// Returns the occurrences already flattened
    /// (`IncrementalState.occurrences`, a `flatMap` over all entries): that
    /// work also stays here, on the actor's thread, not on the MainActor that
    /// receives the result.
    func full(blocks: [TextBlock], analysis: AnalysisRecord) -> [Repetitions.Occurrence] {
        let result = Repetitions.computeFull(blocks: blocks, analysis: analysis)
        state = result
        return result.occurrences
    }

    /// Incremental recomputation: a single block changed (manual mark
    /// added/changed/removed, that block's analysis arrived or was
    /// regenerated). Without a previous state (the first computation of this
    /// actor's session) it falls back to `full` by itself.
    func incremental(blocks: [TextBlock], analysis: AnalysisRecord, changedBlockId: String) -> [Repetitions.Occurrence] {
        guard let state else { return full(blocks: blocks, analysis: analysis) }
        let result = Repetitions.update(state: state, blocks: blocks, analysis: analysis, changedBlockIds: [changedBlockId])
        self.state = result
        return result.occurrences
    }

    /// Tests only: clears the internal state, so the next call is forced to
    /// do a full computation instead of an incremental one.
    func reset() {
        state = nil
    }
}
