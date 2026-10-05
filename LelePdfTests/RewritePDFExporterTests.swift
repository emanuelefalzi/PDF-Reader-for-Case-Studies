import Foundation
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// "PDF" (SPEC §8.2): the generated PDF reads back with PDFKit, the text is
/// there and in the right order (contents heading → points/sub-points), as
/// required ("generated PDF parsed back with PDFKit"), with no generated
/// header and no card title (same structure as the `.docx`/Copy with
/// Formatting).
@MainActor
@Suite("RewritePDFExporter")
struct RewritePDFExporterTests {
    private func sampleDocument(paragraphCount: Int = 1) -> RewriteExportDocument {
        var nodes: [RewriteExportNode] = [
            .heading(text: "Capitolo 1", level: 1),
            .outlineLine(.point, [.init(text: "Punto principale")]),
            .outlineLine(.subpoint, [.init(text: "Un sottopunto")]),
        ]
        for index in 0 ..< paragraphCount {
            nodes.append(.outlineLine(.explanation, [.init(text: "Paragrafo numero \(index) ripetuto molte volte per riempire più di una pagina del PDF esportato quando serve.")]))
        }
        return RewriteExportDocument(
            header: .init(documentTitle: "Documento PDF di prova", sectionLabel: "Tutto il documento", pagesLabel: "p. 1-3"),
            nodes: nodes
        )
    }

    @Test("the generated PDF reopens with PDFKit and contains the text, in document order, with no generated heading")
    func generatesReadablePDF() throws {
        let data = try #require(RewritePDFExporter.data(for: sampleDocument()))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount >= 1)

        var fullText = ""
        for pageIndex in 0 ..< pdf.pageCount {
            fullText += pdf.page(at: pageIndex)?.string ?? ""
        }
        #expect(!fullText.contains("Documento PDF di prova"), "no generated heading in the PDF body")
        #expect(fullText.contains("Capitolo 1"))
        #expect(fullText.contains("Punto principale"))
        #expect(fullText.contains("Un sottopunto"))

        // Order: the main point before its sub-point.
        let bulletRange = try #require(fullText.range(of: "Punto principale"))
        let subBulletRange = try #require(fullText.range(of: "Un sottopunto"))
        #expect(bulletRange.lowerBound < subBulletRange.lowerBound)
    }

    @Test("a document longer than a US Letter page produces more than one page, without losing text")
    func multiPageWhenContentOverflows() throws {
        let data = try #require(RewritePDFExporter.data(for: sampleDocument(paragraphCount: 40)))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 1)

        var fullText = ""
        for pageIndex in 0 ..< pdf.pageCount {
            fullText += pdf.page(at: pageIndex)?.string ?? ""
        }
        #expect(fullText.contains("Paragrafo numero 0 "))
        #expect(fullText.contains("Paragrafo numero 39 "))
    }

    @Test("a document with no nodes still produces a valid PDF, with no heading")
    func emptyBodyStillProducesValidPDF() throws {
        let empty = RewriteExportDocument(header: .init(documentTitle: "Solo intestazione", sectionLabel: "Sezione corrente", pagesLabel: "p. 1"), nodes: [])
        let data = try #require(RewritePDFExporter.data(for: empty))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount >= 1)
        let pageText = (pdf.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pageText.isEmpty)
    }
}
