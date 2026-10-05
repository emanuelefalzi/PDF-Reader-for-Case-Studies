import Foundation
import Observation

/// Per-window analysis queue (SPEC §5.5, §6.3), on top of the single app-wide
/// `BatchRunner` process. Design choice: `@MainActor @Observable` instead of a
/// dedicated `actor`. The queue must publish live state to the SwiftUI UI
/// (pill, progress bar, placeholder cards) on every transition, and never does
/// heavy work itself (the CPU-bound `AnalysisPostProcessor.process` on a block
/// of ≤700 words is sub-millisecond anyway); an `actor` would have required an
/// asynchronous/Sendable bridge to Observation for every single state change,
/// with no real concurrency benefit since there is a single `BatchRunner`
/// acting as the bottleneck anyway.
@MainActor
@Observable
final class AnalysisQueue {
    /// Snapshot of the document data needed to build the input of an analysis
    /// (SPEC §7.5): the caller (`AnalysisController`) updates it on every
    /// structure/analysis change.
    struct DocumentContext: Sendable {
        var fingerprint: String
        var documentTitle: String
        /// In document order (`structure.blocks`).
        var blocks: [TextBlock]
        var exhibits: [ExhibitRef]
        var analysis: AnalysisRecord
        var lastAnalyzedBlockId: String?
        /// Granularity chosen for the document, passed to Claude's input
        /// (`AnalysisInputBuilder`) so the prompt can adapt the outline density
        /// to the block's width (a chapter must not become thirty points).
        var summaryGranularity: SummaryGranularity = .heading3
    }

    static let maxQueued = 5

    let runner: BatchRunner
    let store: DocumentStore
    /// Not `private`: also used by `AnalysisQueue+Execution.swift` (same type,
    /// a separate file only to keep files small, not a real encapsulation
    /// boundary).
    let defaults: UserDefaults
    private(set) var model: ClaudeModel

    // Not `private(set)`: `AnalysisQueue+Execution.swift` (same type, separate
    // file) must be able to write them. The only API meant for those outside
    // the type remains the public methods below (`state(for:)`,
    // `analyzeNext`, ...); direct access to these fields from outside the
    // Analysis module is not intended even though they are technically
    // `internal`.
    var context: DocumentContext?
    var order: [String] = [] // queued, FIFO, excludes the running one
    var runningBlockId: String?
    var runningStartedAt: Date?
    var usageLimitResetAt: Date?
    var waitingBlockId: String?

    var failures: [String: ClaudeError] = [:]
    var tasks: [String: Task<Void, Never>] = [:]
    var forceRetryBlockIds: Set<String> = []

    /// Called after every successful analysis (or regeneration), on the
    /// MainActor: the caller (`AnalysisController`) uses it to invalidate its
    /// own derived caches (rectangles per page, segments).
    var onAnalysisSaved: (@MainActor (String) -> Void)?

    init(store: DocumentStore, runner: BatchRunner = .shared, defaults: UserDefaults = AppRuntime.defaults) {
        self.store = store
        self.runner = runner
        self.defaults = defaults
        self.model = AnalysisModelPreference.read(defaults: defaults)
    }

    // MARK: - Context (SPEC: updated on every structure/analysis change)

    func updateContext(_ newContext: DocumentContext) {
        context = newContext
    }

    // MARK: - State (SPEC §5.5)

    func state(for blockId: String) -> BlockQueueState {
        // `waitingBlockId` before `runningBlockId`: this queue already
        // considers the block "running" as soon as its `Task` starts (SPEC
        // §5.5), but until `BatchRunner` has handed it the shared slot (SPEC
        // §6.3) it stays "waiting for another window". `BatchRunner` does not
        // expose a distinct signal for "the slot arrived, it is really running
        // now" (only `onWaiting`, called once before queueing): an accepted
        // approximation, so the state stays `.waitingOtherWindow` for the
        // whole duration of the call, not just the actual wait, since
        // changing `BatchRunner`'s API is out of scope here (this queue is a
        // layer above it).
        if waitingBlockId == blockId {
            return .waitingOtherWindow
        }
        if blockId == runningBlockId {
            return .running(startedAt: runningStartedAt ?? Date(), estimatedSeconds: AnalysisETA.estimate(defaults: defaults))
        }
        if let position = order.firstIndex(of: blockId) {
            return .queued(position: position + 1)
        }
        if let failure = failures[blockId] {
            return .failed(failure)
        }
        if context?.analysis.blocks[blockId]?.status == .analyzed {
            return .analyzed
        }
        return .idle
    }

    /// SPEC §5.5 "12 of 58 blocks": analyzed out of total.
    var progress: (analyzed: Int, total: Int) {
        guard let context else { return (0, 0) }
        let analyzed = context.blocks.filter { context.analysis.blocks[$0.id]?.status == .analyzed }.count
        return (analyzed, context.blocks.count)
    }

    // MARK: - Commands (SPEC §5.5)

    /// First non-analyzed block after the one at the current reading
    /// position; if there are none further ahead, the first non-analyzed one
    /// from the start. No-op if there are none (SPEC: not an error), or if the
    /// queue is already full.
    func analyzeNext(fromReadingPosition currentBlockId: String?) {
        guard let context, order.count < Self.maxQueued else { return }
        guard let target = Self.nextUnanalyzedBlock(
            blocks: context.blocks, analysis: context.analysis, after: currentBlockId,
            excluding: { [self] id in id == runningBlockId || order.contains(id) }
        ) else { return }
        enqueue(target)
    }

    /// "Analyze this section" and a placeholder's button (SPEC §5.5, §5.5
    /// "goes in the queue, max 5, in order"): into the FIFO queue like
    /// `analyzeNext`/`enqueue`, not at the head. An earlier version jumped to
    /// the head of the queue ("an explicit user jump wins over an earlier
    /// automatic enqueue"), which, with SEVERAL pills pressed in a row (A then
    /// B then C), put them in reverse order, the last one pressed always being
    /// next: SPEC says "in order" with no exceptions for this button. If the
    /// queue is already full and the block is not already queued, the oldest
    /// queued item gives up its place (unchanged: an explicit user jump must
    /// not be left without a slot just because the automatic queue already
    /// filled it).
    func analyze(blockId: String) {
        guard let context, context.blocks.contains(where: { $0.id == blockId }) else { return }
        guard runningBlockId != blockId else { return }
        order.removeAll { $0 == blockId }
        if runningBlockId == nil {
            start(blockId: blockId)
        } else {
            if order.count >= Self.maxQueued { order.removeFirst() }
            order.append(blockId)
        }
    }

    /// Cancels a queued block (removed immediately) or the running one
    /// (cooperative cancellation: `BatchRunner.run` notices the `Task`
    /// cancellation even in the middle of a network call; SPEC §6.3/§5.5
    /// "cancellable").
    func cancel(blockId: String) {
        if runningBlockId == blockId {
            tasks[blockId]?.cancel()
        } else if order.contains(blockId) {
            order.removeAll { $0 == blockId }
            failures[blockId] = nil
        }
    }

    /// Retries a block in the `.failed` state (SPEC §5.5 "Retry"), forcing a
    /// bypass of the usage-limit fast-fail if that was the reason for the
    /// failure (SPEC §5.12 "'Retry' ... forces a new attempt anyway").
    func retry(blockId: String) {
        guard failures[blockId] != nil, let context, context.blocks.contains(where: { $0.id == blockId }) else { return }
        failures[blockId] = nil
        forceRetryBlockIds.insert(blockId)
        if runningBlockId == nil {
            start(blockId: blockId)
        } else if !order.contains(blockId) {
            order.insert(blockId, at: 0)
        }
    }

    // MARK: - Next block selection (pure, SPEC §5.5)

    /// `nonisolated`: pure, no queue state, so it can be called from a test
    /// context not isolated to MainActor without a hop.
    nonisolated static func nextUnanalyzedBlock(
        blocks: [TextBlock], analysis: AnalysisRecord, after currentBlockId: String?,
        excluding: (String) -> Bool = { _ in false }
    ) -> String? {
        let ids = blocks.map(\.id)
        guard !ids.isEmpty else { return nil }
        func isCandidate(_ id: String) -> Bool {
            analysis.blocks[id]?.status != .analyzed && !excluding(id)
        }

        let startIndex: Int
        if let currentBlockId, let idx = ids.firstIndex(of: currentBlockId) {
            startIndex = idx + 1
        } else {
            startIndex = 0
        }
        if startIndex < ids.count {
            for i in startIndex ..< ids.count where isCandidate(ids[i]) { return ids[i] }
        }
        for i in 0 ..< min(startIndex, ids.count) where isCandidate(ids[i]) { return ids[i] }
        return nil
    }

}
