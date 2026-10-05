import AppKit
import Foundation

/// Choice of the summary granularity for the document. Kept in a file
/// separate from `DocumentModel.swift` to keep files short.
@MainActor
extension DocumentModel {
    /// Value shown by the controls (menu, right panel, Contents tab): the
    /// saved choice, or the default from Settings if the user has not yet
    /// chosen for this document, for the UI ONLY. A Picker still needs a
    /// concrete value; `hasChosenSummaryGranularity` below tells "already
    /// chosen" from "still on the default".
    var effectiveSummaryGranularity: SummaryGranularity {
        documentRecord?.summaryGranularity ?? initialSummaryGranularity
    }

    /// False for an existing document not yet migrated (the previous
    /// segmentation, `BlockSegmenter.segment(paragraphs:)`, by the internal
    /// `Paragraph.sectionPath`), true as soon as the user has explicitly
    /// chosen any granularity (even one equal to the default); from then on
    /// segmentation follows the T1-T4 contents
    /// (`BlockSegmenter.segment(paragraphs:tocEntries:granularity:)`).
    var hasChosenSummaryGranularity: Bool {
        documentRecord?.summaryGranularity != nil
    }

    /// How many CURRENTLY valid analyses (`status == .analyzed`) would
    /// become orphans by switching to `granularity`: a pure preview, it
    /// writes nothing. `0` if the count cannot be computed (pipeline not
    /// ready yet, no document registered): the UI is never blocked for
    /// missing information, the real action (`applySummaryGranularity`) is
    /// a no-op in the same case anyway.
    func previewOrphanCount(for granularity: SummaryGranularity) async -> Int {
        guard let plan = computeGranularityPlan(for: granularity), let storeFingerprint else { return 0 }
        guard let analysis = await AppStore.shared.currentAnalysis(fingerprint: storeFingerprint) else { return 0 }
        let previousBlocks = documentRecord?.blocks ?? []
        let result = DocumentStore.reattach(previousBlocks: previousBlocks, newBlocks: plan.records, analysisBlocks: analysis.blocks, usePositionalFallback: false, requireExactSpanForIdMatch: true)
        let orphanedIds = Set(result.orphans.map(\.blockId))
        return orphanedIds.filter { analysis.blocks[$0]?.status == .analyzed }.count
    }

    /// Applies a granularity: recomputes the
    /// blocks from the current contents (`tocEntries`, already
    /// visible/sorted) and from the paragraphs already extracted by the
    /// pipeline (`structure.paragraphs`, never repeating the extraction),
    /// saves them re-attaching the existing analyses (id -> textHash ->
    /// position, the SAME rule as any other segmentation change, SPEC §7.3)
    /// and records the choice in `documento.json`. Analyses that do not
    /// re-attach stay `orphan`: never lost, shown/exportable at the old page
    /// until they are redone (SPEC §7.3).
    func applySummaryGranularity(_ granularity: SummaryGranularity) async {
        guard let plan = computeGranularityPlan(for: granularity), let storeFingerprint, let structure else { return }
        let orphans = await AppStore.shared.updateStructure(
            fingerprint: storeFingerprint,
            toc: TocRecord(source: tocSource == .generated ? .generated : .native, entries: documentRecord?.toc.entries ?? []),
            segmentationVersion: SegmentationVersion.current,
            blocks: plan.records,
            exhibits: documentRecord?.exhibits ?? [],
            usePositionalFallback: false,
            requireExactSpanForIdMatch: true
        )
        await AppStore.shared.updateSummaryGranularity(fingerprint: storeFingerprint, granularity: granularity)
        guard let (finalRecord, finalAnalysis, finalAnnotations) = await AppStore.shared.loadRecordAndAnalysis(fingerprint: storeFingerprint) else { return }
        orphanBlocks = orphans
        // The new `structure.blocks` (full TextBlocks, needed for the clean text
        // passed to Claude) must be replaced BEFORE `applyStoreResult` (which
        // ends by calling `refreshAnalysisContext`, read from
        // `structure?.blocks`); without this order `analysisController` would
        // receive old blocks inconsistent with what was just saved.
        self.structure = DocumentStructure(
            fingerprint: structure.fingerprint, pageCount: structure.pageCount, headings: structure.headings,
            tocCandidates: structure.tocCandidates, exhibits: structure.exhibits, blocks: plan.textBlocks,
            textlessPages: structure.textlessPages, removedHeaderFooterLines: structure.removedHeaderFooterLines,
            paragraphs: structure.paragraphs
        )
        applyStoreResult(fingerprint: storeFingerprint, record: finalRecord, analysis: finalAnalysis, annotations: finalAnnotations)
        readerBridge?.updateDebugAnnotations(structure: self.structure, show: debugShowBlocks)
    }

    /// The real action of the menu/right panel/Contents tab: it decides the
    /// UX on its own. If the change would not lose any valid analysis
    /// (`previewOrphanCount == 0`) it applies immediately, without
    /// interrupting the user for a harmless operation; otherwise it asks for
    /// confirmation with the EXACT count, making it explicit that the old
    /// analyses stay readable/exportable; the confirmation is about REDOING
    /// the work, never about losing it. A direct modal `NSAlert` (like
    /// `SettingsView.chooseWordTemplate`), not a SwiftUI `.alert`: this
    /// action also starts from the "Contents" menu (`ContentsCommands`),
    /// outside any view hierarchy.
    func requestSummaryGranularityChange(to granularity: SummaryGranularity) {
        guard granularity != effectiveSummaryGranularity else { return }
        Task { [weak self] in
            guard let self else { return }
            let affected = await self.previewOrphanCount(for: granularity)
            guard affected > 0 else {
                await self.applySummaryGranularity(granularity)
                return
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "Change summary granularity?")
            let plural = affected == 1 ? String(localized: "summary") : String(localized: "summaries")
            alert.informativeText = String(localized: "\(affected) existing \(plural) will no longer match a block and will need to be redone. The old ones stay readable and exportable until you re-analyze them.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Switch to \(granularity.label)"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                await self.applySummaryGranularity(granularity)
            }
        }
    }

    /// Silent, no confirmation: to be called only when the GENERATED contents
    /// arrives/changes (`attachStructureToStore`/`startTocGeneration`),
    /// never from a single manual edit of a T1-T4 entry. While the user is
    /// still fixing the contents (before choosing the granularity/starting
    /// the analysis, the flow they have in mind) a recomputation on every
    /// touch would just be wasted work. No-op if nothing has been chosen
    /// yet.
    func recomputeBlocksForChosenGranularityIfNeeded() {
        guard let granularity = documentRecord?.summaryGranularity else { return }
        Task { [weak self] in
            await self?.applySummaryGranularity(granularity)
        }
    }

    struct GranularityPlan {
        var textBlocks: [TextBlock]
        var records: [BlockRecord]
    }

    private func computeGranularityPlan(for granularity: SummaryGranularity) -> GranularityPlan? {
        guard let structure else { return nil }
        let textBlocks = BlockSegmenter.segment(paragraphs: structure.paragraphs, tocEntries: tocEntries, granularity: granularity)
        let records = textBlocks.map {
            BlockRecord(id: $0.id, sectionPath: $0.sectionPath, pageStart: $0.pageStart, pageEnd: $0.pageEnd, textHash: $0.textHash, words: $0.words)
        }
        return GranularityPlan(textBlocks: textBlocks, records: records)
    }
}
