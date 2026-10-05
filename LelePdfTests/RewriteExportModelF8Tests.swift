import Foundation
import Testing
@testable import LelePdf

/// Two properties specific to the summary granularity work, on the export
/// model (existing and unchanged elsewhere: `RewriteExportModelTests`).
@Suite("RewriteExportModel · summary granularity")
struct RewriteExportModelF8Tests {
    /// The headings in the Word export stay driven by the contents, whatever
    /// the granularity: headings come ONLY from `document.toc.entries`
    /// (unchanged by the granularity work). Two different BLOCK structures
    /// (simulating two different granularities on the same contents) must
    /// produce EXACTLY the same `.heading` nodes.
    @MainActor
    @Test("the same contents headings appear whatever the block segmentation (granularity)")
    func headingsUnaffectedByBlockGranularity() {
        let toc = TocRecord(source: .native, entries: [
            TocEntryRecord(id: "t1", title: "Chapter 1", level: 1, page: 0),
            TocEntryRecord(id: "t2", title: "1.1", level: 2, page: 0),
            TocEntryRecord(id: "t3", title: "1.1.1", level: 3, page: 1),
        ])

        // "Heading 3": small blocks, one per heading.
        var fineDocument = StoreFixtures.sampleDocumentRecord()
        fineDocument.toc = toc
        fineDocument.blocks = [
            BlockRecord(id: "f1", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "hf1", words: 50),
            BlockRecord(id: "f2", sectionPath: [], pageStart: 1, pageEnd: 1, textHash: "hf2", words: 50),
        ]
        var fineAnalysis = AnalysisRecord()
        fineAnalysis.blocks["f1"] = BlockAnalysis(status: .analyzed, title: "F1", rewrite: [RewriteItem(kind: .paragraph, text: "Contenuto uno.")])
        fineAnalysis.blocks["f2"] = BlockAnalysis(status: .analyzed, title: "F2", rewrite: [RewriteItem(kind: .paragraph, text: "Contenuto due.")])

        // "Chapter": a SINGLE block covering all the pages of the same
        // chapter (same contents, coarser segmentation).
        var coarseDocument = StoreFixtures.sampleDocumentRecord()
        coarseDocument.toc = toc
        coarseDocument.blocks = [BlockRecord(id: "c1", sectionPath: [], pageStart: 0, pageEnd: 1, textHash: "hc1", words: 100)]
        var coarseAnalysis = AnalysisRecord()
        coarseAnalysis.blocks["c1"] = BlockAnalysis(status: .analyzed, title: "C1", rewrite: [RewriteItem(kind: .paragraph, text: "Contenuto unico.")])

        let fineHeadings = RewriteExportModel.build(document: fineDocument, analysis: fineAnalysis, scope: .wholeDocument, currentBlockId: nil)
            .nodes.compactMap { node -> RewriteExportNode? in if case .heading = node { node } else { nil } }
        let coarseHeadings = RewriteExportModel.build(document: coarseDocument, analysis: coarseAnalysis, scope: .wholeDocument, currentBlockId: nil)
            .nodes.compactMap { node -> RewriteExportNode? in if case .heading = node { node } else { nil } }

        let expectedHeadings: [RewriteExportNode] = [
            .heading(text: "Chapter 1", level: 1),
            .heading(text: "1.1", level: 2),
            .heading(text: "1.1.1", level: 3),
        ]
        #expect(fineHeadings == expectedHeadings)
        #expect(coarseHeadings == expectedHeadings)
    }

    /// "Keep old ones readable and exportable until replaced". `orphans` go
    /// at the end, under a dedicated heading, ONLY in the whole-document
    /// scope.
    @MainActor
    @Test("orphaned analyses stay exportable, at the end, with their own title/page")
    func orphanAnalysesAreExported() {
        var document = StoreFixtures.sampleDocumentRecord()
        document.toc = TocRecord(source: .native, entries: [TocEntryRecord(id: "t1", title: "Chapter 1", level: 1, page: 0)])
        document.blocks = [BlockRecord(id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "h1", words: 20)]

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, title: "Current", rewrite: [RewriteItem(kind: .paragraph, text: "Testo attuale.")])
        analysis.blocks["orphan-1"] = BlockAnalysis(status: .orphan, title: "Old Section", rewrite: [RewriteItem(kind: .paragraph, text: "Vecchio contenuto.")])

        let orphans = [OrphanBlock(blockId: "orphan-1", page: 4)]
        let export = RewriteExportModel.build(document: document, analysis: analysis, scope: .wholeDocument, currentBlockId: nil, orphans: orphans)

        #expect(export.nodes.contains(.heading(text: "Saved analyses (previous blocks)", level: 4)))
        #expect(export.nodes.contains(.outlineLine(.subheading, [RewriteExportRun(text: "Old Section -- p. 5")])))
        #expect(export.nodes.contains(.outlineLine(.explanation, [RewriteExportRun(text: "Vecchio contenuto.")])))
    }

    /// Without `orphans` (default `[]`, callers/tests predating this work): no
    /// change, same behavior as before.
    @MainActor
    @Test("without the orphans parameter the result stays identical to before")
    func omittingOrphansParameterKeepsPriorBehavior() {
        var document = StoreFixtures.sampleDocumentRecord()
        document.toc = TocRecord(source: .native, entries: [])
        document.blocks = [BlockRecord(id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "h1", words: 20)]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, title: "Current", rewrite: [RewriteItem(kind: .paragraph, text: "Testo attuale.")])

        let export = RewriteExportModel.build(document: document, analysis: analysis, scope: .wholeDocument, currentBlockId: nil)
        #expect(!export.nodes.contains { if case .heading(let text, _) = $0 { text.contains("Saved analyses") } else { false } })
    }

    /// "Current section" scope: orphans no longer have a meaningful
    /// `sectionPath`, so they do not appear, consistent with
    /// `exhibits(for:)`/`tocEntries(for:)`, which already filter by page range
    /// in that scope.
    @MainActor
    @Test("current section: orphans do not appear")
    func orphansExcludedFromCurrentSectionScope() {
        var document = StoreFixtures.sampleDocumentRecord()
        document.toc = TocRecord(source: .native, entries: [TocEntryRecord(id: "t1", title: "Chapter 1", level: 1, page: 0)])
        document.blocks = [BlockRecord(id: "b1", sectionPath: ["Chapter 1"], pageStart: 0, pageEnd: 0, textHash: "h1", words: 20)]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, title: "Current", rewrite: [RewriteItem(kind: .paragraph, text: "Testo attuale.")])
        analysis.blocks["orphan-1"] = BlockAnalysis(status: .orphan, title: "Old Section", rewrite: [RewriteItem(kind: .paragraph, text: "Vecchio contenuto.")])

        let export = RewriteExportModel.build(document: document, analysis: analysis, scope: .currentSection, currentBlockId: "b1", orphans: [OrphanBlock(blockId: "orphan-1", page: 4)])
        #expect(!export.nodes.contains { if case .heading(let text, _) = $0 { text.contains("Saved analyses") } else { false } })
    }
}
