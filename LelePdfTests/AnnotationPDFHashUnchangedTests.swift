import Testing
import Foundation
import CryptoKit
@preconcurrency import PDFKit
@testable import LelePdf

/// Without the explicit "Save marks to PDF" command (and with the
/// automatic option off by default), annotating and closing does not change
/// the PDF. Same technique as `PDFFileDocumentTests`: `PDFFileDocument`
/// keeps the original bytes separate from any `PDFDocument` built for
/// display — annotations are added ONLY to the latter.
@Suite("Annotation PDF hash unchanged")
@MainActor
struct AnnotationPDFHashUnchangedTests {
    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("annotating every kind then 'closing' the document does not change the PDF hash")
    func annotatingDoesNotChangeFileBytes() throws {
        let url = try StoreFixtures.makeTextPDF(text: "Testo di prova per l'impronta e le annotazioni.")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let originalData = try Data(contentsOf: url)
        let originalHash = sha256(originalData)

        let fileDocument = PDFFileDocument(data: originalData, displayName: url.lastPathComponent)
        let viewingDocument = try #require(PDFDocument(data: fileDocument.data))
        let originalPageCount = viewingDocument.pageCount
        let originalAnnotationCount = (0 ..< originalPageCount).reduce(0) { count, index in
            count + (viewingDocument.page(at: index)?.annotations.count ?? 0)
        }

        // One annotation of every kind, as `AnnotationController` would create
        // them after use case §12.21 (highlight, underline, draw, arrow, textbox,
        // note...).
        let annotations = AnnotationKind.allCases.enumerated().map { index, kind -> Annotation in
            Annotation(
                id: "a\(index)", page: 0, kind: kind, color: AnnotationColor(red: 1, green: 0.9, blue: 0.25, alpha: 1),
                fillColor: AnnotationColor(red: 0, green: 0.5, blue: 1, alpha: 0.5), lineWidth: 3,
                rect: AnnotationRect(x: 10, y: 10, width: 40, height: 40),
                points: [AnnotationPoint(x: 10, y: 10), AnnotationPoint(x: 50, y: 50)], text: "prova"
            )
        }
        let renderer = AnnotationRenderer(document: viewingDocument)
        renderer.refreshAll(annotations)

        // Proves the test is not vacuous: the annotations were really added to
        // the display `PDFDocument`. Not an exact comparison: PDFKit itself adds a
        // paired `.popup` for a text note (`.text`) as soon as it is given content,
        // so the final count may slightly exceed the expected one.
        let annotatedCount = (0 ..< originalPageCount).reduce(0) { count, index in
            count + (viewingDocument.page(at: index)?.annotations.count ?? 0)
        }
        #expect(annotatedCount >= originalAnnotationCount + annotations.count)

        // "Closing" the document (SPEC §6.2 "`fileWrapper(configuration:)` returns
        // the original file unchanged"): the bytes remain those at open time,
        // never those of the annotated `PDFDocument`.
        #expect(sha256(fileDocument.data) == originalHash)
        let wrapper = fileDocument.makeUnchangedFileWrapper()
        let wrapperData = try #require(wrapper.regularFileContents)
        #expect(sha256(wrapperData) == originalHash)

        // Even when rewriting to disk (as `DocumentGroup` would), the resulting
        // file's hash does not change.
        let rewrittenURL = url.deletingLastPathComponent().appendingPathComponent("riscritto-annotato.pdf")
        try wrapperData.write(to: rewrittenURL)
        #expect(sha256(try Data(contentsOf: rewrittenURL)) == originalHash)
    }
}
