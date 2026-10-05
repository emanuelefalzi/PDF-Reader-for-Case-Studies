import Foundation

/// Mutations of `annotazioni.json` (SPEC §8 v2.4, §5.13, M7b): the same
/// scheme as `updateAnalysis` (`DocumentStore+Mutations.swift`), a generic
/// mutator, so `AnnotationController` decides the exact change without the
/// Store knowing the annotation/undo-redo logic.
extension DocumentStore {
    /// Applies `mutate` to the in-memory `annotazioni.json`, then schedules
    /// the write (500 ms debounce) and the Markdown export (2 s, SPEC §5.13
    /// "Export: ... highlights ... notes").
    func updateAnnotations(fingerprint: String, _ mutate: @Sendable (inout AnnotationsRecord) -> Void) {
        guard var current = pending[fingerprint] else { return }
        mutate(&current.annotations)
        pending[fingerprint] = current
        scheduleAnnotationsSave(fingerprint: fingerprint)
        scheduleMarkdownExport(fingerprint: fingerprint)
    }
}
