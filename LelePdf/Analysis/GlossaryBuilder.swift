import Foundation

/// Sorts the term registry for the input glossary (SPEC §7.5: "up to 60, the
/// most recent and frequent"). Design choice: since "most recent and
/// frequent" depends both on the registry (`AnalysisRecord.terms`) and on how
/// many times and where each term appears in the marks already saved, the
/// function takes the whole `AnalysisRecord` plus the document's block order
/// (to establish what "most recent" means), rather than receiving
/// precomputed counts. It is still pure (no state, no I/O) and fully
/// testable.
enum GlossaryBuilder {
    static let defaultLimit = 60

    static func build(analysis: AnalysisRecord, blockOrder: [String], limit: Int = defaultLimit) -> [AnalysisInputBuilder.GlossaryEntry] {
        guard !analysis.terms.isEmpty else { return [] }
        let orderIndex = Dictionary(uniqueKeysWithValues: blockOrder.enumerated().map { ($1, $0) })

        var frequency: [String: Int] = [:]
        var lastSeenIndex: [String: Int] = [:]
        for (blockId, blockAnalysis) in analysis.blocks {
            guard blockAnalysis.status == .analyzed else { continue }
            let blockIndex = orderIndex[blockId] ?? -1
            for mark in blockAnalysis.marks where !mark.hidden {
                frequency[mark.termId, default: 0] += 1
                lastSeenIndex[mark.termId] = max(lastSeenIndex[mark.termId] ?? -1, blockIndex)
            }
        }

        let sortedTermIds = analysis.terms.keys.sorted { lhs, rhs in
            let freqL = frequency[lhs] ?? 0, freqR = frequency[rhs] ?? 0
            if freqL != freqR { return freqL > freqR }
            let recentL = lastSeenIndex[lhs] ?? -1, recentR = lastSeenIndex[rhs] ?? -1
            if recentL != recentR { return recentL > recentR }
            return lhs < rhs // tie: stable, deterministic order
        }

        return sortedTermIds.prefix(limit).compactMap { termId in
            guard let record = analysis.terms[termId] else { return nil }
            return AnalysisInputBuilder.GlossaryEntry(termId: termId, term: record.term, type: record.type)
        }
    }
}
