import CryptoKit
import Foundation

/// Store for the saved data (SPEC §6.3 "Dedicated actors for TextPipeline,
/// Store and AnalysisQueue"; SPEC §8). A single instance shared by the app,
/// per data folder; the tests create one per temporary folder.
///
/// It never touches PDFKit: it only receives `Sendable` values already
/// extracted on the MainActor (fingerprint, page count, title); the real
/// extraction stays with `DocumentFingerprint`/`PipelineRunner` (SPEC §6.3).
actor DocumentStore {
    struct Pending {
        var record: DocumentRecord
        var analysis: AnalysisRecord
        /// Latest version seen on disk by this instance. Needed for the
        /// three-way merge when a second process writes in the meantime.
        var persistedAnalysis: AnalysisRecord
        /// Like `persistedAnalysis`, but for `documento.json` (structure and
        /// progress).
        var persistedRecord: DocumentRecord
        var folderName: String
        /// `annotazioni.json` (SPEC §8 v2.4, M7b): loaded lazily by
        /// `loadRecordAndAnalysis`/`registerDocument` like `record`/`analysis`;
        /// see `DocumentStore+Annotations.swift`.
        var annotations: AnnotationsRecord = AnnotationsRecord()
    }

    static let debounceInterval: Duration = .milliseconds(500)
    static let markdownDelay: Duration = .seconds(2)

    /// UserDefaults key for the data folder chosen in Settings (SPEC §5.11,
    /// M10). `LELEPDF_DATA_DIR` always takes precedence (used by autonomous
    /// verification runs, SPEC M3 item 6).
    static let dataFolderDefaultsKey = "dataFolderPath"

    // Explicit `nonisolated` (M10, Summary Lab): the data folder does not
    // change after `init` (SPEC §5.11 "it changes new opens, not the current
    // one"), so it is safe to read synchronously from outside the actor. It
    // is needed by `AnalysisInstructions` to find
    // `istruzioni-riscrittura.md` without an `await` at every point that
    // composes the prompt (`AnalysisQueue+Execution`, Summary Lab).
    nonisolated let dataFolderURL: URL
    private(set) var index: FingerprintIndex
    var pending: [String: Pending] = [:]

    var recordSaveTasks: [String: Task<Void, Never>] = [:]
    var analysisSaveTasks: [String: Task<Void, Never>] = [:]
    /// `annotazioni.json` (SPEC §8 v2.4, M7b): the same debounce scheme as
    /// `analysisSaveTasks`, see `DocumentStore+Persistence.swift`.
    var annotationSaveTasks: [String: Task<Void, Never>] = [:]
    var markdownTasks: [String: Task<Void, Never>] = [:]
    var indexSaveTask: Task<Void, Never>?

    /// Fingerprints for which this instance (a process/a session) has already
    /// made the start-of-session safety copy (see
    /// `makeSessionSafetyCopyIfNeeded`). It does not persist across restarts:
    /// it must not.
    var sessionSafetyDone: Set<String> = []

    /// Counters of the writes actually performed on disk (not of the
    /// requests), used only by the tests to verify debounce batching
    /// (SPEC §8 "batched every 500 ms").
    var recordWriteCount = 0
    var analysisWriteCount = 0
    var annotationWriteCount = 0
    var markdownWriteCount = 0

    init(dataFolderURL override: URL? = nil) {
        let resolved = Self.resolveDataFolder(override: override)
        dataFolderURL = resolved
        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        if let loaded = AtomicJSONFile.decode(FingerprintIndex.self, from: resolved.appendingPathComponent(".indice.json")) {
            index = loaded
        } else {
            index = Self.rebuildIndex(scanning: resolved)
        }
    }

    // MARK: - Folder name (SPEC §8)

    static func sanitizedTitle(_ title: String) -> String {
        var sanitized = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty { sanitized = "Document" }
        if sanitized.count > 80 { sanitized = String(sanitized.prefix(80)) }
        return sanitized
    }

    static func folderName(title: String, fingerprint: String) -> String {
        "\(sanitizedTitle(title)) [\(fingerprint.prefix(8))]"
    }

    // MARK: - File byte fingerprint (fast path, SPEC §8)

    /// SHA-256 of the file's bytes, read in 1 MB chunks (incremental
    /// CryptoKit) instead of loading it all into memory: it runs on the
    /// actor's executor, never on the MainActor.
    static func hashFileBytes(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1_000_000) } catch { break }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Lookup (SPEC §8)

    /// Fast path: fingerprint and folder already known for this file byte
    /// hash, without having to recompute the real fingerprint from the text.
    func lookupByByteHash(_ hash: String) -> (fingerprint: String, folderName: String)? {
        guard let fingerprint = index.byteHashToFingerprint[hash],
              let folder = index.fingerprintToFolder[fingerprint] else { return nil }
        return (fingerprint, folder)
    }

    func lookupFolder(forFingerprint fingerprint: String) -> String? {
        index.fingerprintToFolder[fingerprint]
    }

    /// After annotations are written into the PDF, the bytes change but the
    /// text fingerprint stays identical. This registers the new fast hash on
    /// the same identity, so `documento.json` is found immediately on reopen
    /// without waiting for the text pipeline.
    func associateCurrentByteHash(fileURL: URL, fingerprint: String) {
        guard index.fingerprintToFolder[fingerprint] != nil,
              let hash = Self.hashFileBytes(at: fileURL),
              index.byteHashToFingerprint[hash] != fingerprint else { return }
        index.byteHashToFingerprint[hash] = fingerprint
        scheduleIndexSave()
    }

    /// Result of the fast path (SPEC §8, M3 item 4): the file's byte hash is
    /// always computed (useful even on a miss, to register the document later
    /// without having to recompute it), record/analysis only if already
    /// known.
    struct FastLookupResult: Sendable {
        var byteHash: String?
        var fingerprint: String?
        var record: DocumentRecord?
        var analysis: AnalysisRecord?
        var annotations: AnnotationsRecord?
    }

    /// Entry point for `DocumentModel`: hashes the file's bytes (off the
    /// MainActor, on the actor's executor) and looks in the index. If the
    /// document is already known it immediately returns `documento.json`/
    /// `analisi.json`, without waiting for the pipeline to recompute the real
    /// fingerprint (SPEC §5.2 "within 1 s").
    func fastLookup(fileURL: URL) -> FastLookupResult {
        let hash = Self.hashFileBytes(at: fileURL)
        guard let hash, let hit = lookupByByteHash(hash) else {
            return FastLookupResult(byteHash: hash, fingerprint: nil, record: nil, analysis: nil, annotations: nil)
        }
        let loaded = loadRecordAndAnalysis(fingerprint: hit.fingerprint)
        return FastLookupResult(
            byteHash: hash, fingerprint: hit.fingerprint, record: loaded?.record, analysis: loaded?.analysis, annotations: loaded?.annotations
        )
    }

    /// Loads (from the actor's memory if already open in this session,
    /// otherwise from disk) `documento.json`/`analisi.json`/`annotazioni.json`
    /// for a fingerprint already in the index. `nil` if the fingerprint has
    /// never been seen.
    func loadRecordAndAnalysis(fingerprint: String) -> (record: DocumentRecord, analysis: AnalysisRecord, annotations: AnnotationsRecord)? {
        if let cached = pending[fingerprint] {
            return (cached.record, cached.analysis, cached.annotations)
        }
        guard let folder = index.fingerprintToFolder[fingerprint] else { return nil }
        let record = loadRecordFromDisk(folderName: folder) ?? DocumentRecord.blank(
            fingerprint: fingerprint, fileName: folder, lastKnownPath: "", pageCount: 0, title: folder
        )
        let analysis = loadAnalysisFromDisk(folderName: folder)
        let annotations = loadAnnotationsFromDisk(folderName: folder)
        pending[fingerprint] = Pending(
            record: record,
            analysis: analysis,
            persistedAnalysis: analysis,
            persistedRecord: record,
            folderName: folder,
            annotations: annotations
        )
        return (record, analysis, annotations)
    }

    // MARK: - Creation/update (rename, SPEC §8)

    /// Registers a document: creates the folder the first time, otherwise
    /// updates `fileName`/`lastKnownPath` if they changed (rename or move,
    /// SPEC M3 item 4) and the byte-hash map.
    @discardableResult
    func registerDocument(
        fingerprint: String,
        byteHash: String?,
        fileName: String,
        lastKnownPath: String,
        title: String,
        pageCount: Int,
        initialColorTheme: MaterialHue = .default,
        initialSummaryGranularity: SummaryGranularity? = nil
    ) -> (folderName: String, record: DocumentRecord, isNew: Bool) {
        if let existingFolder = index.fingerprintToFolder[fingerprint] {
            var current: Pending
            if let cached = pending[fingerprint] {
                current = cached
            } else {
                let loadedAnalysis = loadAnalysisFromDisk(folderName: existingFolder)
                let loadedRecord = loadRecordFromDisk(folderName: existingFolder) ?? DocumentRecord.blank(
                    fingerprint: fingerprint, fileName: fileName, lastKnownPath: lastKnownPath, pageCount: pageCount, title: title
                )
                current = Pending(
                    record: loadedRecord,
                    analysis: loadedAnalysis,
                    persistedAnalysis: loadedAnalysis,
                    persistedRecord: loadedRecord,
                    folderName: existingFolder,
                    annotations: loadAnnotationsFromDisk(folderName: existingFolder)
                )
            }
            var changed = false
            if current.record.fileName != fileName || current.record.lastKnownPath != lastKnownPath {
                current.record.fileName = fileName
                current.record.lastKnownPath = lastKnownPath
                changed = true
            }
            if current.record.pageCount != pageCount, pageCount > 0 {
                current.record.pageCount = pageCount
                changed = true
            }
            if changed {
                current.record.updatedAt = Date()
            }
            pending[fingerprint] = current
            if let byteHash, index.byteHashToFingerprint[byteHash] != fingerprint {
                index.byteHashToFingerprint[byteHash] = fingerprint
                scheduleIndexSave()
            }
            if changed { scheduleRecordSave(fingerprint: fingerprint) }
            return (existingFolder, current.record, false)
        } else {
            let folder = Self.folderName(title: title, fingerprint: fingerprint)
            var record = DocumentRecord.blank(fingerprint: fingerprint, fileName: fileName, lastKnownPath: lastKnownPath, pageCount: pageCount, title: title)
            record.colorTheme = initialColorTheme
            // Only a NEW document immediately receives the Settings default;
            // an existing document (branch above) never gets here, and stays
            // `nil` until the user chooses.
            record.summaryGranularity = initialSummaryGranularity
            index.fingerprintToFolder[fingerprint] = folder
            if let byteHash { index.byteHashToFingerprint[byteHash] = fingerprint }
            let emptyAnalysis = AnalysisRecord()
            pending[fingerprint] = Pending(
                record: record,
                analysis: emptyAnalysis,
                persistedAnalysis: emptyAnalysis,
                persistedRecord: record,
                folderName: folder
            )
            scheduleIndexSave()
            scheduleRecordSave(fingerprint: fingerprint)
            return (folder, record, true)
        }
    }

    // MARK: - Convenience access (tests and diagnostics)

    func currentRecord(fingerprint: String) -> DocumentRecord? { pending[fingerprint]?.record }
    func currentAnalysis(fingerprint: String) -> AnalysisRecord? { pending[fingerprint]?.analysis }
    func currentAnnotations(fingerprint: String) -> AnnotationsRecord? { pending[fingerprint]?.annotations }
}
