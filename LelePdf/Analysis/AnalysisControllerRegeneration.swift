import Foundation

/// "In progress" state of a targeted regeneration (SPEC §5.6 "Shorter"/"More
/// detailed"/"Rewrite like this…", §7.6): unlike a first analysis
/// (`AnalysisQueue`), a regeneration does not go through the queue (there is
/// still only one `claude` process at a time, guaranteed by `BatchRunner`,
/// SPEC §6.3), but the card must still show the "Claude is analyzing"
/// placeholder with an X to cancel. Kept as a separate extension to keep
/// files small.
@MainActor
extension AnalysisController {
    func isRegenerating(blockId: String) -> Bool {
        regenerationTasks[blockId] != nil
    }

    /// Wraps `regenerate(blockId:instruction:)` (SPEC §7.6) in a `Task` of its
    /// own so that cancellation (`cancelRegeneration`) cooperates with
    /// `BatchRunner` exactly as it does for a first analysis
    /// (`ProcessCancelToken`/`withTaskCancellationHandler` in
    /// `BatchRunner.run`: cancelling THIS `Task` interrupts the call in
    /// progress, not just ignores the result).
    func startRegeneration(blockId: String, instruction: String) {
        guard regenerationTasks[blockId] == nil else { return }
        regenerationTasks[blockId] = Task { [weak self] in
            _ = await self?.regenerate(blockId: blockId, instruction: instruction)
            self?.regenerationTasks[blockId] = nil
        }
    }

    func cancelRegeneration(blockId: String) {
        regenerationTasks[blockId]?.cancel()
        regenerationTasks[blockId] = nil
    }
}
