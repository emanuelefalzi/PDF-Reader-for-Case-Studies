import Foundation

/// Targeted regeneration of a block (SPEC §7.6): same schema and
/// post-processing as a first analysis, but only Claude's marks/links for the
/// block are replaced; manual ones stay intact (SPEC: "Manual marks stay;
/// the block's Claude marks are replaced by the new ones"). The UI (the "…"
/// menu, overwrite confirmation on an edited card) is built on top of this;
/// this file only holds the function.
extension AnalysisController {
    func regenerate(blockId: String, instruction: String) async -> Result<Void, ClaudeError> {
        guard let context, let block = context.blocks.first(where: { $0.id == blockId }) else {
            return .failure(.processFailed(stderrTail: "block not found"))
        }
        let currentAnalysis = context.analysis.blocks[blockId] ?? BlockAnalysis(status: .analyzed)
        guard let systemPrompt = ClaudeResources.promptText(named: "rewrite-block"),
              let schema = ClaudeResources.schemaText(named: "analysis") else {
            return .failure(.processFailed(stderrTail: "Resources/Prompts/rewrite-block.md or Schemas/analysis.schema.json missing from bundle"))
        }

        let previousSummary = AnalysisInputBuilder.previousBlockSummary(blocks: context.blocks, analysis: context.analysis, blockId: blockId)
        let glossary = GlossaryBuilder.build(analysis: context.analysis, blockOrder: context.blocks.map(\.id))
        let currentRewritePlainText = RewritePlainText.render(currentAnalysis.rewrite)
        let prompt = AnalysisInputBuilder.buildRegenerationPrompt(
            documentTitle: context.documentTitle, sectionPath: block.sectionPath, previousBlockSummary: previousSummary,
            glossary: glossary, blockCleanText: block.cleanText, exhibits: context.exhibits,
            currentRewritePlainText: currentRewritePlainText, instruction: instruction,
            granularity: context.summaryGranularity, blockWords: block.words
        )
        let request = BatchRequest(prompt: prompt, model: queue.model, systemPrompt: systemPrompt, jsonSchema: schema)
        let outcome = await queue.runner.run(request) { data in try? JSONDecoder().decode(AnalysisResponseRaw.self, from: data) }

        switch outcome {
        case .failure(let error):
            return .failure(error)
        case .success(let batch):
            let manualMarks = currentAnalysis.marks.filter { $0.source == .manual }
            let output = AnalysisPostProcessor.process(.init(response: batch.value, block: block, existingTerms: context.analysis.terms))
            let manualLinks = ManualLinkDerivation.recomputeManualLinks(
                existingLinks: output.links,
                marks: manualMarks + output.marks,
                cleanText: block.cleanText
            ).filter { $0.source == .manual }

            let saved = await AnalysisPersistence.save(
                store: queue.store, fingerprint: context.fingerprint, blockId: blockId, output: output,
                model: queue.model.rawValue, manualMarks: manualMarks, manualLinks: manualLinks, updateProgress: false
            )
            // updateLastAnalyzed: false — a regeneration is not reading
            // progress. `progress.lastAnalyzedBlockId` only concerns first
            // analyses in document order (it remains the fallback of
            // `AnalysisController.continueBlockId` when the reading position
            // cannot be computed).
            queue.applyLocalContextUpdate(blockId: blockId, blockAnalysis: saved, newTerms: output.newTerms)
            queue.onAnalysisSaved?(blockId)
            return .success(())
        }
    }
}
