import Foundation
import Testing
@testable import LelePdf

/// Markdown export with a non-empty table of contents (M7 brief 3b "T1 ##,
/// T2 ###, T3 ####, T4 #####, block titles one level below the deepest used"):
/// a separate suite from `MarkdownExporterTests` (which deliberately covers the
/// path without a table of contents, `renderLegacyBody`, which predates M7).
@Suite("MarkdownExporter · with table of contents (M7)")
struct MarkdownExporterTocTests {
    private func document(tocEntries: [TocEntryRecord], blocks: [BlockRecord]) -> DocumentRecord {
        DocumentRecord(
            fingerprint: "fp", fileName: "documento.pdf", lastKnownPath: "/tmp/documento.pdf",
            pageCount: 5, title: "Documento con indice",
            toc: TocRecord(source: .generated, entries: tocEntries),
            segmentationVersion: 1, blocks: blocks, exhibits: [],
            progress: ProgressRecord(), updatedAt: Date(timeIntervalSince1970: 1_726_000_000)
        )
    }

    private func analyzedBlock(title: String) -> BlockAnalysis {
        BlockAnalysis(status: .analyzed, analyzedAt: Date(), model: "sonnet", title: title, rewrite: [RewriteItem(kind: .paragraph, text: "Testo.")], rewriteEdited: false, claudeRewrite: [], marks: [], links: [])
    }

    @Test("T1/T2 become ##/### and the block title one level below the deepest used")
    @MainActor
    func headingLevels() {
        let toc = [
            TocEntryRecord(id: "t1", title: "Capitolo Uno", level: 1, page: 0),
            TocEntryRecord(id: "manual-1", title: "Sezione 1.1", level: 2, page: 0, origin: .manual),
        ]
        let blocks = [BlockRecord(id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "h1", words: 10)]
        let analysis = AnalysisRecord(blocks: ["b1": analyzedBlock(title: "Blocco Uno")], terms: [:])
        let markdown = MarkdownExporter.render(document: document(tocEntries: toc, blocks: blocks), analysis: analysis)

        #expect(markdown.contains("## Capitolo Uno"))
        #expect(markdown.contains("### Sezione 1.1"))
        // Deepest level used = T2 → the block is one level below: "####".
        #expect(markdown.contains("#### Blocco Uno · p. 1"))
        #expect(!markdown.contains("##### Blocco Uno"))
    }

    @Test("T4 used: the block title reaches 6 hashes (Markdown limit)")
    @MainActor
    func deepestLevelFourClampsToSix() {
        let toc = [TocEntryRecord(id: "manual-1", title: "Voce T4", level: 4, page: 0, origin: .manual)]
        let blocks = [BlockRecord(id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "h1", words: 10)]
        let analysis = AnalysisRecord(blocks: ["b1": analyzedBlock(title: "Blocco")], terms: [:])
        let markdown = MarkdownExporter.render(document: document(tocEntries: toc, blocks: blocks), analysis: analysis)

        #expect(markdown.contains("##### Voce T4"))
        #expect(markdown.contains("###### Blocco · p. 1"))
    }

    @Test("a tombstone (removed) does not appear as a heading")
    @MainActor
    func tombstoneEntryOmitted() {
        let toc = [
            TocEntryRecord(id: "t1", title: "Capitolo Uno", level: 1, page: 0),
            TocEntryRecord(id: "t2", title: "Rimosso", level: 1, page: 1, origin: .manual, removed: true),
        ]
        let blocks = [BlockRecord(id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "h1", words: 10)]
        let analysis = AnalysisRecord(blocks: ["b1": analyzedBlock(title: "Blocco")], terms: [:])
        let markdown = MarkdownExporter.render(document: document(tocEntries: toc, blocks: blocks), analysis: analysis)

        #expect(markdown.contains("## Capitolo Uno"))
        #expect(!markdown.contains("Rimosso"))
    }

    @Test("several headings on the same page: sorted by descending pageY (topmost first)")
    @MainActor
    func samePageOrderedByPageY() {
        let toc = [
            TocEntryRecord(id: "manual-2", title: "Più in basso", level: 1, page: 0, origin: .manual, pageY: 100),
            TocEntryRecord(id: "manual-1", title: "Più in alto", level: 1, page: 0, origin: .manual, pageY: 500),
        ]
        let markdown = MarkdownExporter.render(document: document(tocEntries: toc, blocks: []), analysis: AnalysisRecord())
        let firstIndex = markdown.range(of: "Più in alto")!.lowerBound
        let secondIndex = markdown.range(of: "Più in basso")!.lowerBound
        #expect(firstIndex < secondIndex)
    }
}
