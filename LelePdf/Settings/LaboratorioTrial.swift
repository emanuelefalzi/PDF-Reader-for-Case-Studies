import Foundation

/// Trial call of the Summary Lab (SPEC §5.14 "Try ... a real call to
/// Claude, counted"): same input/output shape as a real first analysis
/// (`AnalysisQueue+Execution.performAnalysis`), but without
/// `AnalysisPersistence.save` or `applyLocalContextUpdate`: the result
/// never touches `analisi.json` nor the in-memory term registry (M10
/// "trial result never persisted"). Pure with respect to the Store by
/// construction: it does not receive a `DocumentStore`, so it cannot
/// write to it by mistake.
enum LaboratorioTrial {
    struct Request: Sendable {
        var documentTitle: String
        var block: TextBlock
        var previousBlockSummary: String?
        var glossary: [AnalysisInputBuilder.GlossaryEntry]
        var exhibits: [ExhibitRef]
        /// Term registry of the open document, READ-ONLY (SPEC §7.5 point 1
        /// "termId reused"): the trial may reuse an existing termId for the
        /// comparison, but the outcome's `newTerms` is never merged back into the
        /// document.
        var existingTerms: [String: TermRecord]
        /// Text edited in the left editor, not necessarily saved ("the
        /// edited text", not the file on disk).
        var instructions: String
        var model: ClaudeModel
    }

    static func run(_ request: Request, runner: BatchRunner) async -> Result<AnalysisPostProcessor.Output, ClaudeError> {
        guard !request.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.processFailed(stderrTail: "Empty instructions"))
        }
        guard let systemPrompt = AnalysisInstructions.systemPrompt(editableText: request.instructions),
              let schema = ClaudeResources.schemaText(named: "analysis") else {
            return .failure(.processFailed(stderrTail: "Prompts/analysis-contract.md or Schemas/analysis.schema.json missing from bundle"))
        }
        let prompt = AnalysisInputBuilder.buildPrompt(
            documentTitle: request.documentTitle,
            sectionPath: request.block.sectionPath,
            previousBlockSummary: request.previousBlockSummary,
            glossary: request.glossary,
            blockCleanText: request.block.cleanText,
            exhibits: request.exhibits
        )
        let batchRequest = BatchRequest(prompt: prompt, model: request.model, systemPrompt: systemPrompt, jsonSchema: schema)
        let outcome = await runner.run(batchRequest) { data in try? JSONDecoder().decode(AnalysisResponseRaw.self, from: data) }
        switch outcome {
        case .failure(let error):
            return .failure(error)
        case .success(let batch):
            let output = AnalysisPostProcessor.process(.init(response: batch.value, block: request.block, existingTerms: request.existingTerms))
            return .success(output)
        }
    }
}
