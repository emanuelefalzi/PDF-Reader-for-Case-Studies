import Testing
import Foundation
@preconcurrency import PDFKit
@testable import LelePdf

/// SPEC §6.2: the PDF's hash on disk does not change after opening and
/// "closing" a document through `DocumentModel`, even now that the model
/// reads the file to compute its byte hash (SPEC §8): that read must never
/// rewrite the source file. Uses a temporary copy, never the original test
/// PDF.
///
/// `DocumentModel` uses `AppStore.shared`: under XCTest the path is isolated
/// at production level (`DocumentStore.resolveDataFolder`), without reading
/// or modifying the real app's UserDefaults.
@Suite("DocumentModel + Store", .serialized)
@MainActor
struct DocumentModelStoreIntegrationTests {
    @Test("opening and closing through the model do not modify the source PDF")
    func openingThroughModelDoesNotModifySourceFile() async throws {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per il modello.", fileName: "modello.pdf")
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()) }
        let originalHash = try #require(DocumentStore.hashFileBytes(at: sourceURL))

        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "modello")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        // Let the Store's fast path breathe (byte hash + possible lookup in
        // the index): it only reads, it never writes the PDF.
        try await Task.sleep(for: .milliseconds(300))
        model.flushStore()
        try await Task.sleep(for: .milliseconds(200))

        let finalHash = try #require(DocumentStore.hashFileBytes(at: sourceURL))
        #expect(finalHash == originalHash)
    }
}
