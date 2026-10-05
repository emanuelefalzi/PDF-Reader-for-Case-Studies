// Analysis module (SPEC §6.2): the engine that analyzes a block.
//
// - `AnalysisInputBuilder` / `GlossaryBuilder` / `ExhibitCitationSubstitution`:
//   pure construction of the user input (SPEC §7.5 "Input", §7.6).
// - `AnalysisResponseRaw` and related types: raw shape decoded from
//   `structured_output` (SPEC `analysis.schema.json`).
// - `TermRegistry` / `MarkMatcher` / `RewriteProcessing` (`TableTruncation`,
//   `MarkerSanitizer`, `RewritePlainText`): post-processing (SPEC §7.5
//   points 1-2-5).
// - `AnalysisPostProcessor`: post-processing orchestrator, from the raw
//   response to sanitized `Mark`/`Link`/`rewrite` values ready for the Store.
// - `AnalysisPersistence`: saving into `analisi.json` + the `progress` of
//   `documento.json` (SPEC §7.5 last point, §8).
// - `Repetitions`: later occurrences of a term in the analyzed blocks (SPEC
//   §7.5.4), computed at load time, never saved.
// - `BlockQueueState` / `AnalysisETA` / `AnalysisQueue`: per-window queue on
//   top of `BatchRunner` (SPEC §5.5, §6.3).
// - `BlockLabeling`: human-readable label "3.2" of a block (SPEC M5a point 6).
// - `AnalysisController` (+ `AnalysisControllerMarks`, `RegenerateBlock`):
//   the API used by the UI layers, owned by `DocumentModel`.
