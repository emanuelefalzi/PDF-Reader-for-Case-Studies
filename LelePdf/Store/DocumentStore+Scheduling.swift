import Foundation

/// Write debouncing (SPEC §8: batched every 500 ms, the last state "wins")
/// and `flush()` to close/test without waiting. Separate from
/// `DocumentStore+Persistence.swift` (the real reading/writing, three-way
/// merge) only to stay under ~12 KB per file.
extension DocumentStore {
    // MARK: - Debounce (SPEC §8: batched every 500 ms, the last state "wins")

    func scheduleRecordSave(fingerprint: String) {
        guard recordSaveTasks[fingerprint] == nil else { return }
        recordSaveTasks[fingerprint] = Task { [weak self] in
            try? await Task.sleep(for: DocumentStore.debounceInterval)
            guard let self, !Task.isCancelled else { return }
            await self.finishRecordSave(fingerprint: fingerprint)
        }
    }

    private func finishRecordSave(fingerprint: String) async {
        recordSaveTasks[fingerprint] = nil
        writeRecordNow(fingerprint: fingerprint)
    }

    func scheduleAnalysisSave(fingerprint: String) {
        guard analysisSaveTasks[fingerprint] == nil else { return }
        analysisSaveTasks[fingerprint] = Task { [weak self] in
            try? await Task.sleep(for: DocumentStore.debounceInterval)
            guard let self, !Task.isCancelled else { return }
            await self.finishAnalysisSave(fingerprint: fingerprint)
        }
    }

    private func finishAnalysisSave(fingerprint: String) async {
        analysisSaveTasks[fingerprint] = nil
        writeAnalysisNow(fingerprint: fingerprint)
    }

    /// `annotazioni.json` (SPEC §8 v2.4, M7b): the same scheme as
    /// `scheduleAnalysisSave`, with no three-way merge (see
    /// `writeAnnotationsNow`).
    func scheduleAnnotationsSave(fingerprint: String) {
        guard annotationSaveTasks[fingerprint] == nil else { return }
        annotationSaveTasks[fingerprint] = Task { [weak self] in
            try? await Task.sleep(for: DocumentStore.debounceInterval)
            guard let self, !Task.isCancelled else { return }
            await self.finishAnnotationsSave(fingerprint: fingerprint)
        }
    }

    private func finishAnnotationsSave(fingerprint: String) async {
        annotationSaveTasks[fingerprint] = nil
        writeAnnotationsNow(fingerprint: fingerprint)
    }

    /// Markdown export "regenerated 2 s after every change" (SPEC §8), never
    /// reread: no `.bak`, no need to coordinate with reads.
    func scheduleMarkdownExport(fingerprint: String) {
        markdownTasks[fingerprint]?.cancel()
        markdownTasks[fingerprint] = Task { [weak self] in
            try? await Task.sleep(for: DocumentStore.markdownDelay)
            guard let self, !Task.isCancelled else { return }
            await self.finishMarkdownExport(fingerprint: fingerprint)
        }
    }

    private func finishMarkdownExport(fingerprint: String) async {
        markdownTasks[fingerprint] = nil
        writeMarkdownNow(fingerprint: fingerprint)
    }

    func scheduleIndexSave() {
        guard indexSaveTask == nil else { return }
        indexSaveTask = Task { [weak self] in
            try? await Task.sleep(for: DocumentStore.debounceInterval)
            guard let self, !Task.isCancelled else { return }
            await self.finishIndexSave()
        }
    }

    private func finishIndexSave() async {
        indexSaveTask = nil
        writeIndexNow()
    }

    // MARK: - Flush (window close, tests — SPEC M3 item 2)

    /// Writes a document's current state immediately, cancelling any writes
    /// already scheduled (it does not redo them: they read the latest state
    /// anyway).
    func flush(fingerprint: String) {
        recordSaveTasks[fingerprint]?.cancel()
        recordSaveTasks[fingerprint] = nil
        analysisSaveTasks[fingerprint]?.cancel()
        analysisSaveTasks[fingerprint] = nil
        annotationSaveTasks[fingerprint]?.cancel()
        annotationSaveTasks[fingerprint] = nil
        markdownTasks[fingerprint]?.cancel()
        markdownTasks[fingerprint] = nil
        guard pending[fingerprint] != nil else { return }
        writeRecordNow(fingerprint: fingerprint)
        writeAnalysisNow(fingerprint: fingerprint)
        writeAnnotationsNow(fingerprint: fingerprint)
        writeMarkdownNow(fingerprint: fingerprint)
        flushIndex()
    }

    func flushIndex() {
        indexSaveTask?.cancel()
        indexSaveTask = nil
        writeIndexNow()
    }

    func flushAll() {
        for fingerprint in pending.keys {
            flush(fingerprint: fingerprint)
        }
    }
}
