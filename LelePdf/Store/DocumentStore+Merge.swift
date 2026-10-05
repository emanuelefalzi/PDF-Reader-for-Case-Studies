import Foundation

/// Three-way merge (local/baseline/disk) used by `writeRecordNow`/
/// `writeAnalysisNow` (`DocumentStore+Persistence.swift`) so that real work is
/// never lost when two windows/processes write the same document. Isolated
/// in a separate file only to stay under ~12 KB per file: it is pure logic,
/// with no I/O, easy to test and to reread in full.
extension DocumentStore {
    /// Picks the best readable version already present. A non-empty backup
    /// wins over an empty primary, because the app has no explicit removal of
    /// the whole analysis.
    static func preferredAnalysis(primary: AnalysisRecord?, backup: AnalysisRecord?) -> AnalysisRecord {
        if let primary, primary.hasPersistedContent { return primary }
        if let backup, backup.hasPersistedContent { return backup }
        return primary ?? backup ?? AnalysisRecord()
    }

    /// Three-way merge for concurrent windows/processes. Values changed
    /// locally relative to the baseline win; those left unchanged accept the
    /// latest version read from disk. So two processes analyzing different
    /// blocks produce a union instead of losing each other's work.
    static func mergeAnalysis(
        local: AnalysisRecord,
        baseline: AnalysisRecord,
        disk: AnalysisRecord
    ) -> AnalysisRecord {
        var result = disk
        result.version = max(local.version, disk.version)
        result.blocks = mergeDictionary(local: local.blocks, baseline: baseline.blocks, disk: disk.blocks)
        result.terms = mergeDictionary(local: local.terms, baseline: baseline.terms, disk: disk.terms)
        return result
    }

    private static func mergeDictionary<Key: Hashable, Value: Equatable>(
        local: [Key: Value],
        baseline: [Key: Value],
        disk: [Key: Value]
    ) -> [Key: Value] {
        var result = disk
        for key in Set(local.keys).union(baseline.keys) where local[key] != baseline[key] {
            result[key] = local[key]
        }
        return result
    }

    /// Three-way merge for `documento.json`, the same principle as
    /// `mergeAnalysis`: fields changed locally relative to the baseline win,
    /// the others accept the latest version read from disk.
    /// `progress.analyzedBlockIds` never loses an id: an ordered union (first
    /// those already on disk, then the new local ones not yet present), never
    /// a flat replacement.
    static func mergeRecord(local: DocumentRecord, baseline: DocumentRecord, disk: DocumentRecord) -> DocumentRecord {
        var result = disk
        result.version = max(local.version, disk.version)
        if local.fileName != baseline.fileName { result.fileName = local.fileName }
        if local.lastKnownPath != baseline.lastKnownPath { result.lastKnownPath = local.lastKnownPath }
        if local.pageCount != baseline.pageCount { result.pageCount = local.pageCount }
        if local.title != baseline.title { result.title = local.title }
        if local.toc != baseline.toc { result.toc = local.toc }
        if local.segmentationVersion != baseline.segmentationVersion { result.segmentationVersion = local.segmentationVersion }
        if local.blocks != baseline.blocks { result.blocks = local.blocks }
        if local.exhibits != baseline.exhibits { result.exhibits = local.exhibits }
        if local.colorTheme != baseline.colorTheme { result.colorTheme = local.colorTheme }

        var mergedProgress = disk.progress
        var ids = mergedProgress.analyzedBlockIds
        for id in local.progress.analyzedBlockIds where !ids.contains(id) { ids.append(id) }
        mergedProgress.analyzedBlockIds = ids
        if local.progress.lastReadPage != baseline.progress.lastReadPage {
            mergedProgress.lastReadPage = local.progress.lastReadPage
        }
        if local.progress.lastAnalyzedBlockId != baseline.progress.lastAnalyzedBlockId {
            mergedProgress.lastAnalyzedBlockId = local.progress.lastAnalyzedBlockId
        }
        result.progress = mergedProgress
        result.updatedAt = max(local.updatedAt, disk.updatedAt)
        return result
    }
}
