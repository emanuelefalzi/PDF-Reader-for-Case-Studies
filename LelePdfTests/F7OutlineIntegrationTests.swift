import Foundation
import Testing
@testable import LelePdf

/// A `kind == .outline` block as seen by the other consumers of the data
/// model (besides the panel and the Word export, already covered by
/// `OutlineLinesRenderTests`/`RewriteDocxExporterTests`): "Edit text"
/// (`RewriteEditText`), the quality checks (`RewriteFormatQuality`), the
/// Obsidian export (`MarkdownExporter`) and the lazy panel's height estimate
/// (`RewriteRowShape`).
@Suite("An outline block as seen by Edit text, quality, Markdown, lazy panel")
struct F7OutlineIntegrationTests {
    private func sampleOutlineItem() -> RewriteItem {
        RewriteItem(kind: .outline, lines: [
            RewriteLine(type: .point, text: "Primo punto con {{m1|Vioxx}}."),
            RewriteLine(type: .subpoint, text: "Un dettaglio del primo punto."),
            RewriteLine(type: .explanation, text: "Una spiegazione del primo punto."),
            RewriteLine(type: .note, text: "Una nota a parte."),
            RewriteLine(type: .formula, text: "x = y + z"),
            RewriteLine(type: .consequence, text: "Effetto del punto precedente."),
            RewriteLine(type: .subheading, text: "Un titoletto raro"),
            RewriteLine(type: .point, text: "Secondo punto, senza dettagli."),
        ])
    }

    // MARK: - Edit text (RewriteEditText): render → parse is an identity

    @Test("render/parse: the editable text reports exactly the same lines, type by type")
    func editTextRoundTrips() {
        let item = sampleOutlineItem()
        let built = RewriteEditText.render(items: [item])
        #expect(built.text.contains("- Primo punto con Vioxx.")) // marker resolved to the displayed words
        #expect(built.text.contains("  - Un dettaglio del primo punto."))
        #expect(built.text.contains("  ~ Una spiegazione del primo punto."))
        #expect(built.text.contains("! Una nota a parte."))
        #expect(built.text.contains("= x = y + z"))
        #expect(built.text.contains("-> Effetto del punto precedente."))
        #expect(built.text.contains("## Un titoletto raro"))

        let parsed = RewriteEditText.parse(text: built.text, spans: built.spans, originalItems: [item])
        #expect(parsed.count == 1)
        let parsedLines = parsed[0].lines ?? []
        #expect(parsedLines.map(\.type) == item.lines!.map(\.type))
        // The {{m1|...}} marker comes back (the span is still there after the parse).
        #expect(parsedLines[0].text.contains("{{m1|Vioxx}}"))
    }

    @Test("an unrecognized prefix degrades to a plain point, never a crash")
    func unknownPrefixDegradesToPoint() {
        let item = RewriteItem(kind: .outline, lines: [RewriteLine(type: .point, text: "riga originale")])
        let parsed = RewriteEditText.parse(text: "testo libero senza prefisso", spans: [], originalItems: [item])
        #expect(parsed[0].lines == [RewriteLine(type: .point, text: "testo libero senza prefisso")])
    }

    // MARK: - Quality checks

    @Test("bulletsSharePercent counts point/subpoint/explanation/consequence, not note/formula/subheading")
    func bulletsShareCountsOnlyBulletLikeLines() {
        let rewrite = [sampleOutlineItem()]
        let share = RewriteFormatQuality.bulletsSharePercent(rewrite)
        // "Primo punto con Vioxx." + "Un dettaglio del primo punto." +
        // "Una spiegazione del primo punto." + "Effetto del punto
        // precedente." + "Secondo punto, senza dettagli." are the only ones
        // that count: note/formula/subheading stay out, so the share must
        // be clearly below 100% but above 0%.
        #expect(share > 0 && share < 100, "unexpected share: \(share)%")
    }

    @Test("mainBulletCount counts level-0 point+consequence, not nested sub-points/explanations")
    func mainBulletCountCountsTopLevelOnly() {
        // 3 level-0 "bullet" lines: two `point` + one `consequence`.
        #expect(RewriteFormatQuality.mainBulletCount([sampleOutlineItem()]) == 3)
    }

    @Test("maxDepth is 2 when there is at least one sub-point/explanation")
    func maxDepthDetectsNesting() {
        #expect(RewriteFormatQuality.maxDepth([sampleOutlineItem()]) == 2)
        let flat = RewriteItem(kind: .outline, lines: [RewriteLine(type: .point, text: "solo un punto")])
        #expect(RewriteFormatQuality.maxDepth([flat]) == 1)
    }

    @Test("totalWords includes every line (also note/formula/subheading)")
    func totalWordsIncludesEveryLine() {
        let manualTotal = sampleOutlineItem().lines!.reduce(0) { $0 + RewriteFormatQuality.wordCount($1.text) }
        #expect(RewriteFormatQuality.totalWords([sampleOutlineItem()]) == manualTotal)
    }

    // MARK: - Obsidian export (MarkdownExporter, SPEC §8)

    @Test("MarkdownExporter: same convention as RewriteCopyExporter for every line type")
    func markdownExportUsesSameConvention() {
        let rendered = MarkdownExporter.renderRewriteItem(sampleOutlineItem(), marks: [
            Mark(id: "m1", termId: "t1", type: .circle, text: "Vioxx", source: .claude, page: 0, range: MarkRange(start: 0, length: 5)),
        ])
        // The "circle" mark (m1) becomes "**...**" in this exporter
        // (`MarkdownExporter.renderMarkerToken`, consistent with Obsidian).
        #expect(rendered.contains("- Primo punto con **Vioxx**."))
        #expect(rendered.contains("  - Un dettaglio del primo punto."))
        #expect(rendered.contains("  *Una spiegazione del primo punto.*"))
        #expect(rendered.contains("> [!note] Una nota a parte."))
        #expect(rendered.contains("> x = y + z"))
        #expect(rendered.contains("- → Effetto del punto precedente."))
        #expect(rendered.contains("**Un titoletto raro**"))
    }

    // MARK: - Lazy panel (RewriteRowShape)

    @Test("RewriteRowShape/estimator: an outline block produces a shape with one entry per line and a positive height")
    func rowShapeEstimatesPositiveHeight() {
        var analysis = BlockAnalysis(status: .analyzed, rewrite: [sampleOutlineItem()])
        analysis.title = "Prova"
        let shape = RewriteRowShape.shape(for: .block(id: "row-b1", blockId: "b1"), analysis: analysis)
        guard case let .card(items) = shape else {
            Issue.record("expected .card, found \(shape)")
            return
        }
        #expect(items.count == 1)
        #expect(items[0].outlineLines.count == 8)
        let height = RewriteRowHeightEstimator.estimate(shape, width: 392)
        #expect(height > 0)
    }
}
