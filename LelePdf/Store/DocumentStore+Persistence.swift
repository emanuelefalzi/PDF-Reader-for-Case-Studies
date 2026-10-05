import Foundation

/// Disk writes, batched every 500 ms per file (SPEC §8), Markdown export
/// 2 s after the last change, and `flush()` to close/test without waiting for
/// the debounce.
extension DocumentStore {
    func folderURL(_ folderName: String) -> URL {
        dataFolderURL.appendingPathComponent(folderName, isDirectory: true)
    }

    private func documentoURL(_ folderName: String) -> URL {
        folderURL(folderName).appendingPathComponent("documento.json")
    }

    private func analisiURL(_ folderName: String) -> URL {
        folderURL(folderName).appendingPathComponent("analisi.json")
    }

    private func annotazioniURL(_ folderName: String) -> URL {
        folderURL(folderName).appendingPathComponent("annotazioni.json")
    }

    private func markdownURL(_ folderName: String) -> URL {
        folderURL(folderName).appendingPathComponent("riscrittura.md")
    }

    private var indexURL: URL {
        dataFolderURL.appendingPathComponent(".indice.json")
    }

    // MARK: - Reading from disk

    /// A corrupt or unreadable `documento.json` → falls back to `.bak`
    /// (written by `writeRecordNow` after the fix for concurrent writers) and
    /// repairs the main file, the same scheme as `loadAnalysisFromDisk`.
    func loadRecordFromDisk(folderName: String) -> DocumentRecord? {
        let url = documentoURL(folderName)
        if let data = ICloudAccess.coordinatedRead(url),
           let value = try? AtomicJSONFile.decoder.decode(DocumentRecord.self, from: data) {
            return value
        }
        let backupURL = url.appendingPathExtension("bak")
        guard let backupData = ICloudAccess.coordinatedRead(backupURL),
              let backupValue = try? AtomicJSONFile.decoder.decode(DocumentRecord.self, from: backupData) else {
            return nil
        }
        try? ICloudAccess.coordinatedWrite(backupData, to: url, keepBackup: false)
        return backupValue
    }

    /// A corrupt or unreadable `analisi.json` → falls back to `.bak` and
    /// repairs the main file (SPEC M3: "no file stays corrupt"); if that is
    /// missing too, an empty analysis (a document never analyzed).
    func loadAnalysisFromDisk(folderName: String) -> AnalysisRecord {
        let url = analisiURL(folderName)
        let backupURL = url.appendingPathExtension("bak")
        let primaryData = ICloudAccess.coordinatedRead(url)
        let primary = primaryData.flatMap { try? AtomicJSONFile.decoder.decode(AnalysisRecord.self, from: $0) }
        let backupData = ICloudAccess.coordinatedRead(backupURL)
        let backup = backupData.flatMap { try? AtomicJSONFile.decoder.decode(AnalysisRecord.self, from: $0) }

        if let primary, primary.hasPersistedContent || backup?.hasPersistedContent != true {
            return primary
        }
        // An empty primary with a non-empty backup is not considered an
        // intentional removal: no user action in the app today deletes the
        // whole analysis. It repairs the primary without rotating away the
        // only good copy.
        if let backup, let backupData, backup.hasPersistedContent {
            try? ICloudAccess.coordinatedWrite(backupData, to: url, keepBackup: false)
            return backup
        }
        return primary ?? backup ?? AnalysisRecord()
    }

    /// Besides the `.bak` updated on every write, the very first time THIS
    /// instance (a process, a session) writes a given file
    /// (`analisi.json`/`documento.json`) it also keeps a copy of what it
    /// found on disk *before* touching it (`<file>.session-start`).
    /// Overwritten on every new session (one file per document, it does not
    /// accumulate): a last safety net beyond `.bak` in case a bug in this
    /// same session's logic (merge, write) also damaged the regular backup in
    /// the same run, before any healthy write regenerates it.
    private func makeSessionSafetyCopyIfNeeded(url: URL) {
        guard !sessionSafetyDone.contains(url.path) else { return }
        sessionSafetyDone.insert(url.path)
        guard let data = ICloudAccess.coordinatedRead(url), !data.isEmpty else { return }
        let safetyURL = url.appendingPathExtension("session-start")
        try? data.write(to: safetyURL, options: .atomic)
    }

    /// A missing or unreadable `annotazioni.json` → no annotations (SPEC
    /// §5.13: never block the open for this; unlike `analisi.json` it has no
    /// `.bak` because at worst any lost annotation is redone by hand and
    /// does not require a new call to Claude).
    func loadAnnotationsFromDisk(folderName: String) -> AnnotationsRecord {
        guard let data = ICloudAccess.coordinatedRead(annotazioniURL(folderName)),
              let value = try? AtomicJSONFile.decoder.decode(AnnotationsRecord.self, from: data) else {
            return AnnotationsRecord()
        }
        return value
    }

    // MARK: - Writing to disk (called only by the debounced tasks or by `flush`)

    /// Like `writeAnalysisNow`: reads `documento.json` under coordination,
    /// does a three-way merge with what this instance has already seen on
    /// disk and with the latest in-memory version, then writes with a backup.
    /// Without this, a process/window with an older cache (for example one
    /// lacking the latest analysis progress written by another window) risked
    /// silently regressing `progress.analyzedBlockIds`/`toc`/`blocks` in
    /// `documento.json`, returning already analyzed blocks to the "orphan" or
    /// "not yet analyzed" state at the next re-attach (`updateStructure`).
    func writeRecordNow(fingerprint: String) {
        guard var current = pending[fingerprint] else { return }
        let local = current.record
        let baseline = current.persistedRecord
        let url = documentoURL(current.folderName)
        makeSessionSafetyCopyIfNeeded(url: url)
        do {
            let resolved = try ICloudAccess.coordinatedUpdate(url) { coordinatedURL in
                let disk = AtomicJSONFile.decode(DocumentRecord.self, from: coordinatedURL) ?? local
                var merged = Self.mergeRecord(local: local, baseline: baseline, disk: disk)
                // The same final guard as `writeAnalysisNow`: an
                // initial/stale state cannot wipe out a real structure/progress
                // already present on disk.
                if !merged.hasPersistedContent, disk.hasPersistedContent {
                    merged = disk
                }
                let data = try AtomicJSONFile.encode(merged)
                try AtomicJSONFile.write(data, to: coordinatedURL, keepBackup: true)
                return merged
            }
            current.record = resolved
            current.persistedRecord = resolved
            pending[fingerprint] = current
            recordWriteCount += 1
        } catch {
            // Like the Store's other writes: an I/O error must not crash the
            // app. The pending version stays available for a later flush.
        }
    }

    func writeAnalysisNow(fingerprint: String) {
        guard var current = pending[fingerprint] else { return }
        let local = current.analysis
        let baseline = current.persistedAnalysis
        let url = analisiURL(current.folderName)
        makeSessionSafetyCopyIfNeeded(url: url)
        do {
            let resolved = try ICloudAccess.coordinatedUpdate(url) { coordinatedURL in
                let primary = AtomicJSONFile.decode(AnalysisRecord.self, from: coordinatedURL)
                let backupURL = coordinatedURL.appendingPathExtension("bak")
                let backup = AtomicJSONFile.decode(AnalysisRecord.self, from: backupURL)
                let disk = Self.preferredAnalysis(primary: primary, backup: backup)

                var merged = Self.mergeAnalysis(local: local, baseline: baseline, disk: disk)
                // Final guard: an initial/stale state cannot wipe out a
                // non-empty file. The app has no explicit "remove all
                // analyses" command yet.
                if !merged.hasPersistedContent, disk.hasPersistedContent {
                    merged = disk
                }

                let data = try AtomicJSONFile.encode(merged)
                // If the primary is empty/corrupt but the backup is good,
                // do not rotate the primary over the only valid copy.
                let keepBackup = primary?.hasPersistedContent == true || backup?.hasPersistedContent != true
                try AtomicJSONFile.write(data, to: coordinatedURL, keepBackup: keepBackup)
                return merged
            }
            current.analysis = resolved
            current.persistedAnalysis = resolved
            pending[fingerprint] = current
            analysisWriteCount += 1
        } catch {
            // Like the Store's other writes: an I/O error must not crash the
            // app. The pending version stays available for a later flush.
        }
    }

    /// No three-way merge here (unlike record/analysis): at worst a lost
    /// document is re-annotated by hand and does not require a new call to
    /// Claude, consistent with `loadAnnotationsFromDisk` above.
    func writeAnnotationsNow(fingerprint: String) {
        guard let current = pending[fingerprint], let data = try? AtomicJSONFile.encode(current.annotations) else { return }
        try? ICloudAccess.coordinatedWrite(data, to: annotazioniURL(current.folderName), keepBackup: false)
        annotationWriteCount += 1
    }

    func writeMarkdownNow(fingerprint: String) {
        guard let current = pending[fingerprint] else { return }
        let markdown = MarkdownExporter.render(document: current.record, analysis: current.analysis, annotations: current.annotations)
        try? ICloudAccess.coordinatedWrite(Data(markdown.utf8), to: markdownURL(current.folderName), keepBackup: false)
        markdownWriteCount += 1
    }

    /// `.indice.json` is the fingerprint↔folder/hash map. Before this fix a
    /// write always overwrote it with only the in-memory state of THIS
    /// instance: a second process that had in the meantime registered a
    /// different document (never seen by this instance) saw its own entry
    /// vanish from the index at this instance's next `flushIndex()`. That does
    /// not destroy that document's `documento.json`/`analisi.json` (protected
    /// separately, and anyway recoverable with `rebuildIndex` if the index
    /// later turned out unreadable), but it makes it temporarily unfindable
    /// from the fast path until something registers it again. Now the index
    /// on disk is read and the entries this instance does not know yet are
    /// kept too, plus a `.bak`.
    func writeIndexNow() {
        var merged = index
        if let disk = AtomicJSONFile.decode(FingerprintIndex.self, from: indexURL) {
            for (fingerprint, folder) in disk.fingerprintToFolder where merged.fingerprintToFolder[fingerprint] == nil {
                merged.fingerprintToFolder[fingerprint] = folder
            }
            for (hash, fingerprint) in disk.byteHashToFingerprint where merged.byteHashToFingerprint[hash] == nil {
                merged.byteHashToFingerprint[hash] = fingerprint
            }
        }
        guard let data = try? AtomicJSONFile.encode(merged) else { return }
        try? ICloudAccess.coordinatedWrite(data, to: indexURL, keepBackup: true)
    }
}
