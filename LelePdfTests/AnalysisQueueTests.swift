import Foundation
import Testing
@testable import LelePdf

/// Per-window analysis queue (SPEC §5.5, §6.3): FIFO,
/// cap of 5, cancelling queued/running items, next-block selection, retry,
/// `waitingOtherWindow` between two queues on the same `BatchRunner`,
/// usage limit.
///
/// The tests are NOT `@MainActor` (unlike `AnalysisQueue`, which is):
/// `withClaudeTestEnv` takes a generic non-isolated closure, and a closure
/// created in a `@MainActor` context that captures MainActor-isolated state
/// (the queue) cannot be "sent" in there under Swift 6 (error "sending
/// non-Sendable value"), without modifying `ClaudeTestSupport.swift`, which
/// is shared by the whole Claude-module suite. Every queue access therefore
/// goes through `await MainActor.run { ... }`.
@Suite("AnalysisQueue")
struct AnalysisQueueTests {
    private func block(_ id: String, page: Int = 0) -> TextBlock {
        let text = "Testo di prova del blocco \(id) con alcune parole."
        return TextBlock(
            id: id, sectionPath: ["Sezione"], pageStart: page, pageEnd: page, cleanText: text,
            textHash: id, words: 8, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
            lineRectsByPage: [:]
        )
    }

    private func tempStore() throws -> (store: DocumentStore, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfAnalysisQueueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DocumentStore(dataFolderURL: dir), { try? FileManager.default.removeItem(at: dir) })
    }

    private func context(blocks: [TextBlock], fingerprint: String = "fp") -> AnalysisQueue.DocumentContext {
        AnalysisQueue.DocumentContext(fingerprint: fingerprint, documentTitle: "Documento", blocks: blocks, exhibits: [], analysis: AnalysisRecord(), lastAnalyzedBlockId: nil)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await MainActor.run(body: condition) == false, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Next-block selection (pure, no queue/CLI involved)

    @Test("first unanalyzed block after the reading position")
    func nextUnanalyzedAfterReadingPosition() {
        let blocks = [block("b1"), block("b2"), block("b3")]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed)
        let next = AnalysisQueue.nextUnanalyzedBlock(blocks: blocks, analysis: analysis, after: "b1")
        #expect(next == "b2")
    }

    @Test("none further ahead: wraps around to the first unanalyzed one from the start")
    func wrapsToStartWhenNoneAfter() {
        let blocks = [block("b1"), block("b2"), block("b3")]
        var analysis = AnalysisRecord()
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed)
        analysis.blocks["b3"] = BlockAnalysis(status: .analyzed)
        let next = AnalysisQueue.nextUnanalyzedBlock(blocks: blocks, analysis: analysis, after: "b2")
        #expect(next == "b1")
    }

    @Test("all analyzed: nil")
    func nilWhenAllAnalyzed() {
        let blocks = [block("b1"), block("b2")]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed)
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed)
        #expect(AnalysisQueue.nextUnanalyzedBlock(blocks: blocks, analysis: analysis, after: "b1") == nil)
    }

    // MARK: - Queue: FIFO, cap of 5, cancellation

    @Test("FIFO up to 5 queued, beyond that nothing is queued; cancel a queued item and the running one")
    func fifoCapAndCancellation() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let blocks = (1 ... 7).map { block("b\($0)") }

        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path, "FAKE_CLAUDE_MODE": "timeout"]) {
            let queue = await MainActor.run { AnalysisQueue(store: store, runner: BatchRunner(timeout: 60), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!) }
            await MainActor.run { queue.updateContext(context(blocks: blocks)) }

            for _ in 0 ..< 7 { await MainActor.run { queue.analyzeNext(fromReadingPosition: nil) } }

            let isRunning = await MainActor.run { queue.state(for: "b1").isRunning }
            #expect(isRunning)
            let order1 = await MainActor.run { queue.order }
            #expect(order1 == ["b2", "b3", "b4", "b5", "b6"])
            let state7 = await MainActor.run { queue.state(for: "b7") }
            #expect(state7 == .idle) // the queue was already full
            let state4 = await MainActor.run { queue.state(for: "b4") }
            #expect(state4 == .queued(position: 3))

            // Cancel a queued item: it disappears, the others keep their order.
            await MainActor.run { queue.cancel(blockId: "b4") }
            let order2 = await MainActor.run { queue.order }
            #expect(order2 == ["b2", "b3", "b5", "b6"])
            let state4After = await MainActor.run { queue.state(for: "b4") }
            #expect(state4After == .idle)

            // Cancel the running one: the queue advances to the next.
            await MainActor.run { queue.cancel(blockId: "b1") }
            await waitUntil { queue.runningBlockId == "b2" }
            let order3 = await MainActor.run { queue.order }
            #expect(order3 == ["b3", "b5", "b6"])

            await MainActor.run { queue.cancel(blockId: "b2") }
            await waitUntil { queue.runningBlockId != "b2" }

            // Every cancel of a RUNNING block advances the queue to the next one
            // (b3, then b5, then b6: "timeout" mode, the fake process stays alive
            // until it is cancelled). Without draining the queue all the way, the
            // last fake process started would be left orphaned past the end of the
            // test (seen in a session: `sleep_forever()` in
            // scripts/fake-claude/claude).
            while let running = await MainActor.run(body: { queue.runningBlockId }) {
                await MainActor.run { queue.cancel(blockId: running) }
                await waitUntil { queue.runningBlockId != running }
            }
        }
    }

    @Test("A, then B, then C pressed with \"Analyze from here\" run in that order, not the last one pressed first")
    func analyzeQueuesInPressOrderNotReversed() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let blocks = [block("a"), block("b"), block("c")]

        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path, "FAKE_CLAUDE_MODE": "timeout"]) {
            let queue = await MainActor.run { AnalysisQueue(store: store, runner: BatchRunner(timeout: 60), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!) }
            await MainActor.run { queue.updateContext(context(blocks: blocks)) }

            // "a" starts right away (no analysis running); "b" then "c" are queued
            // while "a" runs — reported by the user: A, then B, then C must run in
            // the order A → B → C, not C → B (SPEC §5.5 "is queued ... in order").
            await MainActor.run { queue.analyze(blockId: "a") }
            await waitUntil { queue.runningBlockId == "a" }
            await MainActor.run { queue.analyze(blockId: "b") }
            await MainActor.run { queue.analyze(blockId: "c") }

            let order = await MainActor.run { queue.order }
            #expect(order == ["b", "c"])

            await MainActor.run { queue.cancel(blockId: "a") }
            await waitUntil { queue.runningBlockId == "b" }
            let orderAfterA = await MainActor.run { queue.order }
            #expect(orderAfterA == ["c"])

            await MainActor.run { queue.cancel(blockId: "b") }
            await waitUntil { queue.runningBlockId == "c" }

            await MainActor.run { queue.cancel(blockId: "c") }
            await waitUntil { queue.runningBlockId == nil }
        }
    }

    // MARK: - End-to-end success (fake CLI, default mode)

    @Test("successful analysis: .analyzed state, progress and local context updated")
    func successfulAnalysisUpdatesStateAndContext() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let blocks = [block("b1"), block("b2")]

        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let fingerprint = "fp-success"
            _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 2)

            let queue = await MainActor.run { AnalysisQueue(store: store, runner: BatchRunner(timeout: 10), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!) }
            await MainActor.run { queue.updateContext(context(blocks: blocks, fingerprint: fingerprint)) }

            await MainActor.run { queue.analyzeNext(fromReadingPosition: nil) }
            await waitUntil { queue.state(for: "b1") == .analyzed }

            let state1 = await MainActor.run { queue.state(for: "b1") }
            #expect(state1 == .analyzed)
            let contextStatus = await MainActor.run { queue.context?.analysis.blocks["b1"]?.status }
            #expect(contextStatus == .analyzed)
            let lastAnalyzed = await MainActor.run { queue.context?.lastAnalyzedBlockId }
            #expect(lastAnalyzed == "b1")
            let progress = await MainActor.run { queue.progress }
            #expect(progress.analyzed == 1)

            await store.flush(fingerprint: fingerprint)
            let persisted = await store.currentRecord(fingerprint: fingerprint)
            #expect(persisted?.progress.lastAnalyzedBlockId == "b1")
            #expect(persisted?.progress.analyzedBlockIds.contains("b1") == true)
        }
    }

    // MARK: - Retry after a failure

    @Test("retry after a failure: goes back to idle, then to analyzed")
    func retryAfterFailureSucceeds() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let blocks = [block("b1")]

        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path, "FAKE_CLAUDE_MODE": "invalid_json"]) {
            let fingerprint = "fp-retry"
            _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
            let queue = await MainActor.run { AnalysisQueue(store: store, runner: BatchRunner(timeout: 10), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!) }
            await MainActor.run { queue.updateContext(context(blocks: blocks, fingerprint: fingerprint)) }

            await MainActor.run { queue.analyzeNext(fromReadingPosition: nil) }
            await waitUntil { if case .failed = queue.state(for: "b1") { return true } else { return false } }
            let failedState = await MainActor.run { queue.state(for: "b1") }
            guard case .failed(.invalidResponse) = failedState else {
                Issue.record("expected .failed(.invalidResponse), found \(failedState)")
                return
            }

            setenv("FAKE_CLAUDE_MODE", "success", 1)
            await MainActor.run { queue.retry(blockId: "b1") }
            await waitUntil { queue.state(for: "b1") == .analyzed }
            let finalState = await MainActor.run { queue.state(for: "b1") }
            #expect(finalState == .analyzed)
        }
    }

    // MARK: - waitingOtherWindow: two queues on the same BatchRunner

    @Test("waitingOtherWindow: a second queue waits while the first occupies the shared BatchRunner")
    func waitingOtherWindowWithSharedRunner() async throws {
        let (storeA, cleanupA) = try tempStore()
        let (storeB, cleanupB) = try tempStore()
        defer { cleanupA(); cleanupB() }

        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path, "FAKE_CLAUDE_MODE": "timeout"]) {
            let sharedRunner = BatchRunner(timeout: 60)
            let (queueA, queueB) = await MainActor.run {
                (AnalysisQueue(store: storeA, runner: sharedRunner, defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!),
                 AnalysisQueue(store: storeB, runner: sharedRunner, defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!))
            }
            await MainActor.run {
                queueA.updateContext(context(blocks: [block("a1")], fingerprint: "fp-a"))
                queueB.updateContext(context(blocks: [block("b1")], fingerprint: "fp-b"))
            }

            await MainActor.run { queueA.analyzeNext(fromReadingPosition: nil) }
            await waitUntil { queueA.runningBlockId == "a1" }

            await MainActor.run { queueB.analyzeNext(fromReadingPosition: nil) }
            await waitUntil { queueB.state(for: "b1") == .waitingOtherWindow }
            let waitingState = await MainActor.run { queueB.state(for: "b1") }
            #expect(waitingState == .waitingOtherWindow)

            await MainActor.run {
                queueA.cancel(blockId: "a1")
                queueB.cancel(blockId: "b1")
            }
            await waitUntil { queueA.runningBlockId == nil }
            await waitUntil { queueB.runningBlockId == nil }
        }
    }

    // MARK: - Usage limit

    @Test("usage limit: .failed(.usageLimit) state surfaced, retry forces the bypass")
    func usageLimitSurfacesAndForceRetryBypasses() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let blocks = [block("b1")]

        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path, "FAKE_CLAUDE_MODE": "rate_limit"]) {
            let fingerprint = "fp-limit"
            _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
            let queue = await MainActor.run { AnalysisQueue(store: store, runner: BatchRunner(timeout: 10), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!) }
            await MainActor.run { queue.updateContext(context(blocks: blocks, fingerprint: fingerprint)) }

            await MainActor.run { queue.analyzeNext(fromReadingPosition: nil) }
            await waitUntil {
                if case .failed(.usageLimit) = queue.state(for: "b1") { return true } else { return false }
            }
            let limitState = await MainActor.run { queue.state(for: "b1") }
            guard case .failed(.usageLimit(let resetsAt)) = limitState, resetsAt != nil else {
                Issue.record("expected .failed(.usageLimit(resetsAt:)), found \(limitState)")
                return
            }
            let resetAt = await MainActor.run { queue.usageLimitResetAt }
            #expect(resetAt != nil)

            setenv("FAKE_CLAUDE_MODE", "success", 1)
            await MainActor.run { queue.retry(blockId: "b1") } // forces the fast-fail bypass
            await waitUntil { queue.state(for: "b1") == .analyzed }
            let finalState = await MainActor.run { queue.state(for: "b1") }
            #expect(finalState == .analyzed)
        }
    }
}

private extension BlockQueueState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
