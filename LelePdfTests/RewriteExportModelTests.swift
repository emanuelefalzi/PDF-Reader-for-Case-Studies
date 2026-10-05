import Foundation
import Testing
@testable import LelePdf

/// The pure export model (SPEC §8): scope (whole document / current section
/// only), structure (headings ONLY from the contents, points and sub-points,
/// Exhibits), with no card title and no "Normal".
@Suite("RewriteExportModel")
struct RewriteExportModelTests {
    /// Two chapters: "Cap 1" with two sections (b1, b2, pages 0 and 1) and
    /// "Cap 2" with a single block and no section (b3, page 2, NEVER
    /// analyzed; this verifies that the chapter heading appears anyway, as in
    /// the legacy Markdown export, but without a card). One Exhibit on page 1
    /// (between b2 and b3). The contents have the same shape as `sectionPath`
    /// on purpose, to isolate "headings come from the contents, no longer
    /// from sectionPath" without also changing which blocks are included.
    @MainActor
    private func document() -> DocumentRecord {
        var document = StoreFixtures.sampleDocumentRecord()
        document.title = "Documento di prova"
        document.blocks = [
            BlockRecord(id: "b1", sectionPath: ["Cap 1", "Sez A"], pageStart: 0, pageEnd: 0, textHash: "h1", words: 80),
            BlockRecord(id: "b2", sectionPath: ["Cap 1", "Sez B"], pageStart: 1, pageEnd: 1, textHash: "h2", words: 60),
            BlockRecord(id: "b3", sectionPath: ["Cap 2"], pageStart: 2, pageEnd: 2, textHash: "h3", words: 40),
        ]
        document.exhibits = [ExhibitRecord(label: "Exhibit 1", page: 1)]
        document.toc = TocRecord(source: .native, entries: [
            TocEntryRecord(id: "t1", title: "Cap 1", level: 1, page: 0),
            TocEntryRecord(id: "t2", title: "Sez A", level: 2, page: 0),
            TocEntryRecord(id: "t3", title: "Sez B", level: 2, page: 1),
            TocEntryRecord(id: "t4", title: "Cap 2", level: 1, page: 2),
        ])
        return document
    }

    private func analysis() -> AnalysisRecord {
        let marks = [Mark(id: "m1", termId: "t1", type: .rectangle, text: "termine chiave", source: .claude, page: 0, range: MarkRange(start: 0, length: 5))]
        var record = AnalysisRecord()
        record.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Blocco 1",
            rewrite: [RewriteItem(kind: .bullets, items: ["Punto uno {{m1|termine chiave}}", "Punto due"], subItems: [["Dettaglio uno"], []])],
            marks: marks
        )
        record.blocks["b2"] = BlockAnalysis(status: .analyzed, title: "Blocco 2", rewrite: [RewriteItem(kind: .paragraph, text: "Un paragrafo del secondo blocco.")])
        // b3 has no analysis (SPEC: an unanalyzed block is omitted from the card, as in `MarkdownExporter.renderLegacyBody`).
        return record
    }

    @Test("whole document: headings ONLY from the contents, blocks (without a card title), Exhibits in page order; an unanalyzed block is omitted but its chapter heading stays")
    @MainActor
    func wholeDocument() {
        let export = RewriteExportModel.build(document: document(), analysis: analysis(), scope: .wholeDocument, currentBlockId: "b1")

        #expect(export.header.documentTitle == "Documento di prova")
        #expect(export.header.sectionLabel == "Whole Document")
        #expect(export.header.pagesLabel == "p. 1-3")

        let expected: [RewriteExportNode] = [
            .heading(text: "Cap 1", level: 1),
            .heading(text: "Sez A", level: 2),
            .outlineLine(.point, [.init(text: "Punto uno "), .init(text: "termine chiave", emphasis: true)]),
            .outlineLine(.subpoint, [.init(text: "Dettaglio uno")]),
            .outlineLine(.point, [.init(text: "Punto due")]),
            .heading(text: "Sez B", level: 2),
            // An old `kind == .paragraph` becomes a `Spiegazionebullet` line
            // (never a "Normal" node); it is not a meta-summary ("The block
            // traces...").
            .outlineLine(.explanation, [.init(text: "Un paragrafo del secondo blocco.")]),
            .exhibit("Exhibit 1, p. 2"),
            .heading(text: "Cap 2", level: 1),
        ]
        #expect(export.nodes == expected)
    }

    @Test("an old 'The block traces...' summary (a meta-summary from older versions) disappears; a summary of the real content stays as Spiegazionebullet")
    @MainActor
    func dropsMetaSummaryKeepsRealSummary() {
        var document = document()
        document.blocks = [BlockRecord(id: "b1", sectionPath: ["Cap 1"], pageStart: 0, pageEnd: 0, textHash: "h1", words: 10)]
        document.toc = TocRecord(source: .native, entries: [TocEntryRecord(id: "t1", title: "Cap 1", level: 1, page: 0)])
        document.exhibits = []

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, title: "Blocco 1", rewrite: [
            RewriteItem(kind: .summary, text: "While writing the business plan, the founders defined the key roles."),
            RewriteItem(kind: .summary, text: "The block traces the founder's family background and career choices."),
            RewriteItem(kind: .summary, text: "This section describes the timeline of the negotiation."),
        ])

        let export = RewriteExportModel.build(document: document, analysis: analysis, scope: .wholeDocument, currentBlockId: "b1")
        #expect(export.nodes == [
            .heading(text: "Cap 1", level: 1),
            .outlineLine(.explanation, [.init(text: "While writing the business plan, the founders defined the key roles.")]),
        ])
    }

    @Test("current section: only the blocks with the same sectionPath as the focused block, headings filtered by page, out-of-range Exhibit excluded")
    @MainActor
    func currentSectionScope() {
        let export = RewriteExportModel.build(document: document(), analysis: analysis(), scope: .currentSection, currentBlockId: "b1")

        #expect(export.header.sectionLabel == "Cap 1 › Sez A")
        #expect(export.header.pagesLabel == "p. 1")
        let expected: [RewriteExportNode] = [
            .heading(text: "Cap 1", level: 1),
            .heading(text: "Sez A", level: 2),
            .outlineLine(.point, [.init(text: "Punto uno "), .init(text: "termine chiave", emphasis: true)]),
            .outlineLine(.subpoint, [.init(text: "Dettaglio uno")]),
            .outlineLine(.point, [.init(text: "Punto due")]),
        ]
        #expect(export.nodes == expected)
    }

    @Test("current section on a block with only the chapter (no section), never analyzed: only the heading, no card")
    @MainActor
    func currentSectionChapterOnlyUnanalyzed() {
        let export = RewriteExportModel.build(document: document(), analysis: analysis(), scope: .currentSection, currentBlockId: "b3")

        #expect(export.header.sectionLabel == "Cap 2")
        #expect(export.header.pagesLabel == "p. 3")
        #expect(export.nodes == [.heading(text: "Cap 2", level: 1)])
    }

    @Test("current section without a focused block: falls back to the first block of the document")
    @MainActor
    func currentSectionFallsBackToFirstBlock() {
        let export = RewriteExportModel.build(document: document(), analysis: analysis(), scope: .currentSection, currentBlockId: nil)
        #expect(export.header.sectionLabel == "Cap 1 › Sez A")
    }

    @Test("document with no blocks: header without pages, no nodes, no crash")
    @MainActor
    func emptyDocument() {
        var empty = StoreFixtures.sampleDocumentRecord()
        empty.blocks = []
        empty.exhibits = []
        empty.toc = TocRecord(source: .native, entries: [])
        let export = RewriteExportModel.build(document: empty, analysis: AnalysisRecord(), scope: .wholeDocument, currentBlockId: nil)
        #expect(export.header.pagesLabel == "—")
        #expect(export.nodes.isEmpty)
    }

    @Test("document without contents: blocks stay in page order with no heading (they simply continue)")
    @MainActor
    func documentWithoutTocHasNoHeadings() {
        var document = document()
        document.toc = TocRecord(source: .native, entries: [])
        let export = RewriteExportModel.build(document: document, analysis: analysis(), scope: .wholeDocument, currentBlockId: "b1")
        #expect(!export.nodes.contains { if case .heading = $0 { true } else { false } })
    }

    @Test("no exported node ever carries '· p.' in its text (the pages of a card title never go into the text)")
    @MainActor
    func neverEmitsPageSuffixInText() {
        let export = RewriteExportModel.build(document: document(), analysis: analysis(), scope: .wholeDocument, currentBlockId: "b1")
        for node in export.nodes {
            if case let .heading(text, _) = node { #expect(!text.contains("· p.")) }
            if case let .outlineLine(_, runs) = node { #expect(!runs.contains { $0.text.contains("· p.") }) }
        }
    }
}
