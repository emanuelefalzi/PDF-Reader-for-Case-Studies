import Testing
import Foundation
@testable import LelePdf

/// Markdown export of annotations (SPEC §5.13 "Export: ... a section at the
/// end of the chapter 'Annotations · p. N' ... Drawings and shapes are not
/// exported"). It covers both the legacy path (`sectionPath`, no table of
/// contents) and the one with a table of contents (`renderWithToc`); see
/// `MarkdownExporterTests.swift`/`MarkdownExporterTocTests.swift` for the same
/// two paths without annotations.
@Suite("MarkdownExporter+Annotations")
struct MarkdownExporterAnnotationsTests {
    private func annotations() -> AnnotationsRecord {
        AnnotationsRecord(items: [
            Annotation(id: "a1", page: 1, kind: .highlight, color: AnnotationPaletteColor.yellow.color(alpha: 0.55), rect: AnnotationRect(x: 0, y: 0, width: 100, height: 10), text: "termine chiave"),
            Annotation(id: "a2", page: 1, kind: .underline, color: AnnotationPaletteColor.blue.color(), rect: AnnotationRect(x: 0, y: 20, width: 80, height: 10), text: "concetto sottolineato"),
            Annotation(id: "a3", page: 1, kind: .textbox, color: AnnotationPaletteColor.green.color(), rect: AnnotationRect(x: 0, y: 40, width: 60, height: 10), text: "nota a margine"),
            Annotation(id: "a4", page: 1, kind: .note, color: AnnotationPaletteColor.yellow.color(), rect: AnnotationRect(x: 0, y: 60, width: 20, height: 20), text: "promemoria\nsu due righe"),
            // Drawings/shapes: must NOT appear in the export (SPEC).
            Annotation(id: "a5", page: 1, kind: .ink, color: AnnotationPaletteColor.purple.color(), rect: AnnotationRect(x: 0, y: 80, width: 30, height: 30), points: [AnnotationPoint(x: 0, y: 80), AnnotationPoint(x: 30, y: 110)]),
            Annotation(id: "a6", page: 1, kind: .rectangle, color: AnnotationPaletteColor.pink.color(), rect: AnnotationRect(x: 0, y: 120, width: 30, height: 30)),
        ])
    }

    @Test("highlight, underline, text box, and note appear at the end of the chapter; drawings/shapes do not")
    @MainActor
    func legacyBodyIncludesAnnotationSection() {
        var document = StoreFixtures.sampleDocumentRecord()
        document.toc = TocRecord(source: .native, entries: []) // legacy path, as in MarkdownExporterTests.
        let markdown = MarkdownExporter.render(document: document, analysis: StoreFixtures.sampleAnalysisRecord(), annotations: annotations())

        #expect(markdown.contains("Annotations · p. 2")) // page 1 zero-based → "p. 2"
        #expect(markdown.contains("==termine chiave== (yellow)"))
        #expect(markdown.contains("<u>concetto sottolineato</u>"))
        #expect(markdown.contains("nota a margine"))
        #expect(markdown.contains("> [!note] p. 2"))
        #expect(markdown.contains("> promemoria"))
        #expect(markdown.contains("> su due righe"))
        #expect(!markdown.contains("a5")) // no trace of a drawing's id
        #expect(!markdown.contains("a6"))
    }

    @Test("the annotations section comes AFTER the chapter's blocks, not before")
    @MainActor
    func annotationSectionComesAfterBlocks() {
        var document = StoreFixtures.sampleDocumentRecord()
        document.toc = TocRecord(source: .native, entries: [])
        let markdown = MarkdownExporter.render(document: document, analysis: StoreFixtures.sampleAnalysisRecord(), annotations: annotations())

        let blockRange = markdown.range(of: "Secondo blocco")
        let annotationRange = markdown.range(of: "Annotations · p. 2")
        if let blockRange, let annotationRange {
            #expect(blockRange.upperBound < annotationRange.lowerBound)
        } else {
            Issue.record("block or annotations section not found in the Markdown")
        }
    }

    @Test("with a T1-T4 table of contents, the annotations section lands at the end of the chapter (T1 entry)")
    @MainActor
    func rendersWithTocToo() {
        var document = StoreFixtures.sampleDocumentRecord()
        document.toc = TocRecord(source: .native, entries: [TocEntryRecord(id: "t1", title: "Capitolo 1", level: 1, page: 0)])
        let markdown = MarkdownExporter.render(document: document, analysis: StoreFixtures.sampleAnalysisRecord(), annotations: annotations())
        #expect(markdown.contains("Annotations · p. 2"))
        #expect(markdown.contains("==termine chiave== (yellow)"))
    }

    @Test("no annotations: no 'Annotations' section in the export")
    @MainActor
    func noAnnotationsMeansNoSection() {
        var document = StoreFixtures.sampleDocumentRecord()
        document.toc = TocRecord(source: .native, entries: [])
        let markdown = MarkdownExporter.render(document: document, analysis: StoreFixtures.sampleAnalysisRecord())
        #expect(!markdown.contains("Annotazioni ·"))
    }
}
