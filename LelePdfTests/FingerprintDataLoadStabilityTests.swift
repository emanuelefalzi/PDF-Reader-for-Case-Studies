import Foundation
import Testing
@preconcurrency import PDFKit
@testable import LelePdf

/// `DocumentFingerprintStabilityTests` verifies fingerprint stability by
/// loading the PDF with `PDFDocument(url:)`; production code
/// (`DocumentModel.init`, from `PDFFileDocument.data`) always loads with
/// `PDFDocument(data:)` instead (SPEC §6.2 "read-only", the bytes stay in
/// memory from the moment of opening). The two loading paths had never been
/// compared: this suite was added during an investigation of the right panel
/// sometimes being empty (hypothesis: unstable fingerprint) to rule out that
/// loading via `Data`, never exercised by the existing tests, behaves
/// differently from loading via `URL`. Verified: it does not, both paths stay
/// stable and identical to each other on the two real PDFs.
extension HeavyTestSuites {
@Suite("DocumentFingerprint · stability via Data (as DocumentModel does)", .serialized)
@MainActor
struct FingerprintDataLoadStabilityTests {
    @Test("Merck: fingerprint stable when loaded via Data 5 times, and identical to the one via URL")
    func merckStableViaDataAndMatchesURL() throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: Merck PDF not found at \(TestPDFs.merck.path)")
            return
        }
        var fingerprints: Set<String> = []
        for _ in 0 ..< 5 {
            let data = try Data(contentsOf: TestPDFs.merck)
            let document = try #require(PDFDocument(data: data))
            fingerprints.insert(DocumentFingerprint.compute(for: document))
        }
        #expect(fingerprints.count == 1, "different fingerprints across loads via Data: \(fingerprints)")

        let urlDocument = try #require(PDFDocument(url: TestPDFs.merck))
        let fpURL = DocumentFingerprint.compute(for: urlDocument)
        #expect(fingerprints.first == fpURL, "fingerprint via Data differs from the one via URL")
    }

    @Test("Draghi: fingerprint stable when loaded via Data 5 times, and identical to the one via URL")
    func draghiStableViaDataAndMatchesURL() throws {
        guard TestPDFs.ensureAvailable(TestPDFs.draghi) else {
            print("SKIP: Draghi PDF not found at \(TestPDFs.draghi.path)")
            return
        }
        var fingerprints: Set<String> = []
        for _ in 0 ..< 5 {
            let data = try Data(contentsOf: TestPDFs.draghi)
            let document = try #require(PDFDocument(data: data))
            fingerprints.insert(DocumentFingerprint.compute(for: document))
        }
        #expect(fingerprints.count == 1, "different fingerprints across loads via Data: \(fingerprints)")

        let urlDocument = try #require(PDFDocument(url: TestPDFs.draghi))
        let fpURL = DocumentFingerprint.compute(for: urlDocument)
        #expect(fingerprints.first == fpURL, "fingerprint via Data differs from the one via URL")
    }
}
}
