import Testing
import Foundation
import CryptoKit
@preconcurrency import PDFKit
@testable import LelePdf

/// Verifies that the PDF document is truly read-only (SPEC §2, §6.2): the byte
/// hash does not change between opening and "closing" (fileWrapper).
@Suite("PDFFileDocument")
struct PDFFileDocumentTests {
    /// Creates a small valid PDF with CoreGraphics in a temporary folder and
    /// returns its URL.
    static func makeTinyPDF() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("prova.pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 160, height: 160))
        ctx.endPDFPage()
        ctx.closePDF()

        return url
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("the PDF bytes do not change between reading and fileWrapper")
    func roundTripUnchanged() throws {
        let url = try Self.makeTinyPDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let originalData = try Data(contentsOf: url)
        let originalHash = Self.sha256(originalData)
        #expect(!originalData.isEmpty)

        // PDFKit must be able to read the file we generated.
        #expect(PDFDocument(url: url) != nil)

        // Simulates opening the document (SPEC §6.2: fileWrapper(configuration:)
        // returns the original file unchanged).
        let document = PDFFileDocument(data: originalData, displayName: url.lastPathComponent)
        #expect(Self.sha256(document.data) == originalHash)

        // Simulates "closing": the FileWrapper produced must contain exactly the
        // same bytes.
        let wrapper = document.makeUnchangedFileWrapper()
        let wrapperData = try #require(wrapper.regularFileContents)
        #expect(Self.sha256(wrapperData) == originalHash)

        // Writes to disk again (as the document system would) and verifies that
        // the resulting file has the same hash as the original.
        let rewrittenURL = url.deletingLastPathComponent().appendingPathComponent("riscritto.pdf")
        try wrapperData.write(to: rewrittenURL)
        let rewrittenHash = Self.sha256(try Data(contentsOf: rewrittenURL))
        #expect(rewrittenHash == originalHash)
    }
}
