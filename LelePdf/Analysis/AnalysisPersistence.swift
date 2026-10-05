import Foundation

/// Saves the outcome of an analysis (first analysis or targeted regeneration)
/// into the Store (SPEC §7.5 last point, §7.6, §8): `analisi.json` via
/// `DocumentStore.updateAnalysis` (marks, rewrite, term registry) and, for a
/// first analysis, `documento.json.progress` via
/// `DocumentStore.markBlockAnalyzed`. Shared by `AnalysisQueue` and
/// `AnalysisController.regenerate` (SPEC §7.6) so the writing logic is not
/// duplicated. Returns the saved `BlockAnalysis` so the caller can update its
/// own local view of the context (`AnalysisQueue.applyLocalContextUpdate`)
/// without rebuilding it a second time with a different `Date()`.
enum AnalysisPersistence {
    @discardableResult
    static func save(
        store: DocumentStore,
        fingerprint: String,
        blockId: String,
        output: AnalysisPostProcessor.Output,
        model: String,
        manualMarks: [Mark] = [],
        manualLinks: [Link] = [],
        updateProgress: Bool
    ) async -> BlockAnalysis {
        let blockAnalysis = BlockAnalysis(
            status: .analyzed,
            analyzedAt: Date(),
            model: model,
            title: output.title,
            rewrite: output.rewrite,
            rewriteEdited: false,
            claudeRewrite: output.rewrite,
            marks: manualMarks + output.marks,
            links: manualLinks + output.links,
            // Snapshot of Claude's output ONLY (not merged with the manual
            // ones), so that "Restore Claude's Version" can rebuild them
            // exactly even after the user has hidden/changed/removed them
            // from the rewrite. Refreshed on every first analysis or
            // regeneration, like `claudeRewrite`.
            claudeMarks: output.marks,
            claudeLinks: output.links
        )
        await store.updateAnalysis(fingerprint: fingerprint) { record in
            for (termId, term) in output.newTerms {
                record.terms[termId] = term
            }
            record.blocks[blockId] = blockAnalysis
        }
        if updateProgress {
            await store.markBlockAnalyzed(fingerprint: fingerprint, blockId: blockId)
        }
        return blockAnalysis
    }
}
