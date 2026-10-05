import Testing
import Foundation
@testable import LelePdf

/// Markdown export (SPEC §8, §10.2 "Markdown export"): every kind of rewrite
/// element, every kind of mark, a hidden mark, a marker with an unknown id, an
/// Exhibit line, and the `%% lelepdf ... %%` comment after each block.
@Suite("MarkdownExporter")
struct MarkdownExporterTests {
    /// With a non-empty table of contents the export would use
    /// `renderWithToc` instead of the legacy `sectionPath` tested here. This
    /// suite predates the manual contents (M3) and deliberately keeps testing
    /// the path without a table of contents; `renderWithToc` has its own
    /// dedicated suite in `MarkdownExporterTocTests.swift`.
    @MainActor
    private func render() -> String {
        var document = StoreFixtures.sampleDocumentRecord()
        document.toc = TocRecord(source: .native, entries: [])
        return MarkdownExporter.render(document: document, analysis: StoreFixtures.sampleAnalysisRecord())
    }

    @Test("frontmatter YAML")
    @MainActor
    func frontmatter() {
        let markdown = render()
        #expect(markdown.contains("---\ntitle: \"Documento di prova\""))
        #expect(markdown.contains("source: \"documento.pdf\""))
        #expect(markdown.contains("pages: 3"))
        #expect(markdown.contains("fingerprint: abc123def456"))
        #expect(markdown.contains("tags: [lelepdf]"))
    }

    @Test("title, chapter, and section")
    @MainActor
    func headings() {
        let markdown = render()
        #expect(markdown.contains("# Documento di prova"))
        #expect(markdown.contains("## Capitolo 1"))
        #expect(markdown.contains("### Sezione A"))
        // The section does not change between b1 and b2: just one "## Capitolo 1".
        #expect(markdown.components(separatedBy: "## Capitolo 1").count - 1 == 1)
    }

    @Test("block title with page (SPEC §8 '#### Block title · p. 42')")
    @MainActor
    func blockTitlePage() {
        let markdown = render()
        #expect(markdown.contains("#### Primo blocco · p. 1"))
        #expect(markdown.contains("#### Secondo blocco · p. 2"))
    }

    @Test("summary/paragraph as paragraphs, with markers replaced")
    @MainActor
    func summaryAndParagraph() {
        let markdown = render()
        #expect(markdown.contains("Riassunto con ==spesa in R&S== e **Mario Rossi**."))
        #expect(markdown.contains("Un paragrafo semplice."))
    }

    @Test("definition as a blockquote")
    @MainActor
    func definition() {
        let markdown = render()
        #expect(markdown.contains("> **Definition:** Una definizione con marcatore sconosciuto termine ignoto."))
    }

    @Test("marker with an unknown id: the braces are stripped, the text stays")
    @MainActor
    func unknownMarker() {
        let markdown = render()
        #expect(!markdown.contains("{{m9"))
        #expect(markdown.contains("termine ignoto"))
    }

    @Test("hidden mark: plain text, no formatting")
    @MainActor
    func hiddenMark() {
        let markdown = render()
        #expect(markdown.contains("Secondo punto con segno nascosto"))
        #expect(!markdown.contains("==segno nascosto=="))
        #expect(!markdown.contains("\"termId\":\"term-hidden\""))
    }

    @Test("bullets and numbered list")
    @MainActor
    func bulletsAndSteps() {
        let markdown = render()
        #expect(markdown.contains("- Primo punto"))
        #expect(markdown.contains("1. Primo passo"))
        #expect(markdown.contains("2. Secondo passo"))
    }

    @Test("Markdown table")
    @MainActor
    func table() {
        let markdown = render()
        #expect(markdown.contains("| Anno | Valore |"))
        #expect(markdown.contains("| 2024 | 10 |"))
        #expect(markdown.contains("| 2025 | 20 |"))
    }

    @Test("callout with [!note]")
    @MainActor
    func callout() {
        let markdown = render()
        #expect(markdown.contains("> [!note]"))
        #expect(markdown.contains("> Attenzione a questo punto."))
    }

    @Test("underline and arrow (second block)")
    @MainActor
    func underlineAndArrow() {
        let markdown = render()
        #expect(markdown.contains("<u>ha deciso</u>"))
        #expect(markdown.contains("<u>ha causato</u> →"))
    }

    @Test("Exhibit line in document order")
    @MainActor
    func exhibitLine() {
        let markdown = render()
        #expect(markdown.contains("*Exhibit 5, p. 2*"))
    }

    @Test("Obsidian comment after each block")
    @MainActor
    func obsidianComment() {
        let markdown = render()
        #expect(markdown.contains("%% lelepdf: "))
        #expect(markdown.contains("\"block\":\"b1\""))
        #expect(markdown.contains("\"block\":\"b2\""))
        #expect(markdown.contains("\"type\":\"rectangle\""))
        #expect(markdown.contains("\"termId\":\"term-rect\""))
        #expect(markdown.contains("\"term\":\"spesa in R&S\""))
    }
}
