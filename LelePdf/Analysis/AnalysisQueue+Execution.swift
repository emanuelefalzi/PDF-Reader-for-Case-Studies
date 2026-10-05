import Foundation

/// Actual execution of a queued analysis (SPEC §5.5, §7.5): start, call to
/// `BatchRunner` via `AnalysisInputBuilder`/`GlossaryBuilder`, post-processing,
/// saving, advancing to the next one. A separate extension from
/// `AnalysisQueue.swift` only to keep files small, same type: the properties
/// it touches are `internal` (not `private`) for exactly this reason.
extension AnalysisQueue {
    func enqueue(_ blockId: String) {
        guard runningBlockId != blockId, !order.contains(blockId) else { return }
        if runningBlockId == nil, order.isEmpty {
            start(blockId: blockId)
        } else if order.count < Self.maxQueued {
            order.append(blockId)
        }
    }

    func start(blockId: String) {
        guard let context, let block = context.blocks.first(where: { $0.id == blockId }) else { return }
        order.removeAll { $0 == blockId }
        runningBlockId = blockId
        runningStartedAt = Date()
        failures[blockId] = nil
        let forceRetry = forceRetryBlockIds.remove(blockId) != nil

        tasks[blockId] = Task { [weak self] in
            await self?.performAnalysis(blockId: blockId, block: block, context: context, forceRetry: forceRetry)
        }
    }

    private func performAnalysis(blockId: String, block: TextBlock, context: DocumentContext, forceRetry: Bool) async {
        // The effective instructions (SPEC §5.14 "Summary Lab") are the custom
        // file in the data folder if present, otherwise the stock prompt; see
        // `AnalysisInstructions`. The schema always stays the stock one.
        guard let systemPrompt = AnalysisInstructions.effectiveSystemPrompt(dataFolderURL: store.dataFolderURL),
              let schema = ClaudeResources.schemaText(named: "analysis") else {
            finish(blockId: blockId, result: .failure(.processFailed(stderrTail: "Resources/Prompts/analysis.md, analysis-contract.md or Schemas/analysis.schema.json missing from bundle")))
            return
        }

        let previousSummary = AnalysisInputBuilder.previousBlockSummary(blocks: context.blocks, analysis: context.analysis, blockId: blockId)
        let glossary = GlossaryBuilder.build(analysis: context.analysis, blockOrder: context.blocks.map(\.id))
        let prompt = AnalysisInputBuilder.buildPrompt(
            documentTitle: context.documentTitle, sectionPath: block.sectionPath, previousBlockSummary: previousSummary,
            glossary: glossary, blockCleanText: block.cleanText, exhibits: context.exhibits,
            granularity: context.summaryGranularity, blockWords: block.words
        )
        let request = BatchRequest(prompt: prompt, model: model, systemPrompt: systemPrompt, jsonSchema: schema)

        let outcome = await runner.run(request, forceRetry: forceRetry, onWaiting: { [weak self] in
            Task { @MainActor in self?.waitingBlockId = blockId }
        }, decode: { data in try? JSONDecoder().decode(AnalysisResponseRaw.self, from: data) })

        if waitingBlockId == blockId { waitingBlockId = nil }

        switch outcome {
        case .failure(let error):
            finish(blockId: blockId, result: .failure(error))
        case .success(let batch):
            AnalysisETA.record(seconds: Double(batch.durationMs) / 1000, defaults: defaults)
            let output = AnalysisPostProcessor.process(.init(response: batch.value, block: block, existingTerms: context.analysis.terms))
            // A manual mark can already exist on a never-analyzed block (SPEC
            // §5.7: a manual mark on a non-analyzed block is allowed). The
            // real first analysis must not lose it, the same rule already
            // applied by `AnalysisController.regenerate` for regenerations.
            let existing = context.analysis.blocks[blockId]
            let manualMarks = existing?.marks.filter { $0.source == .manual } ?? []
            let manualLinks = ManualLinkDerivation.recomputeManualLinks(
                existingLinks: output.links,
                marks: manualMarks + output.marks,
                cleanText: block.cleanText
            ).filter { $0.source == .manual }
            let saved = await AnalysisPersistence.save(
                store: store, fingerprint: context.fingerprint, blockId: blockId, output: output,
                model: model.rawValue, manualMarks: manualMarks, manualLinks: manualLinks, updateProgress: true
            )
            applyLocalContextUpdate(blockId: blockId, blockAnalysis: saved, newTerms: output.newTerms, updateLastAnalyzed: true)
            finish(blockId: blockId, result: .success(()))
        }
    }

    /// Keeps `context` current right after a successful save (analysis or
    /// targeted regeneration via `AnalysisController.regenerate`), without
    /// having to re-read from the Store: so `state(for:)` immediately reports
    /// `.analyzed` and the next call (glossary, previous block summary) sees
    /// the updated data. `AnalysisController` keeps its own context in sync by
    /// reading `queue.context` (see `onAnalysisSaved`), not a copy of its own.
    func applyLocalContextUpdate(blockId: String, blockAnalysis: BlockAnalysis, newTerms: [String: TermRecord], updateLastAnalyzed: Bool = false) {
        guard var current = context else { return }
        for (termId, term) in newTerms { current.analysis.terms[termId] = term }
        current.analysis.blocks[blockId] = blockAnalysis
        if updateLastAnalyzed, blockAnalysis.status == .analyzed { current.lastAnalyzedBlockId = blockId }
        context = current
    }

    /// Like `applyLocalContextUpdate`, but for undo/redo of manual marks (SPEC
    /// §5.7): unlike that one, `blockAnalysis`/`term` can be `nil` to REMOVE
    /// an entry instead of overwriting it. This is needed to undo an addition
    /// that had created from scratch the `analisi.json` entry for a
    /// not-yet-analyzed block, or the new term it had minted.
    func applyLocalContextUndo(blockId: String, blockAnalysis: BlockAnalysis?, termId: String?, term: TermRecord?) {
        guard var current = context else { return }
        if let termId {
            if let term { current.analysis.terms[termId] = term } else { current.analysis.terms.removeValue(forKey: termId) }
        }
        if let blockAnalysis { current.analysis.blocks[blockId] = blockAnalysis } else { current.analysis.blocks.removeValue(forKey: blockId) }
        context = current
    }

    private func finish(blockId: String, result: Result<Void, ClaudeError>) {
        if runningBlockId == blockId {
            runningBlockId = nil
            runningStartedAt = nil
        }
        tasks[blockId] = nil

        switch result {
        case .success:
            // A successful analysis clears the usage-limit banner (SPEC
            // §5.12): it would otherwise stay visible forever once triggered,
            // since nothing else cleared it.
            usageLimitResetAt = nil
            onAnalysisSaved?(blockId)
        case .failure(let error):
            if case .usageLimit(let resetsAt) = error { usageLimitResetAt = resetsAt }
            if error != .cancelled {
                failures[blockId] = error
            }
        }
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard runningBlockId == nil, let next = order.first else { return }
        start(blockId: next)
    }
}
