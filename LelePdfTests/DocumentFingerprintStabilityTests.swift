import Foundation
import Testing
@preconcurrency import PDFKit
@testable import LelePdf

/// Regression test for a bug found during visual verification with real
/// data: reopening the real Merck PDF after some real analyses produced a new
/// content fingerprint (SPEC §8) different from the previous session's, even
/// though the file (and therefore the byte hash) was identical, so the Store
/// no longer found the saved data and treated it as a new document. Cause:
/// `PDFPage.string` can return empty/incomplete text the very first time it
/// is read on a freshly opened page that PDFKit has not yet "materialized";
/// `DocumentFingerprint.compute(for:)` read each page only once, right after
/// opening. Fixed with a first read-only pass (discarded) before the real one
/// (see `Store/DocumentFingerprint.swift`).
extension HeavyTestSuites {
@Suite("DocumentFingerprint · stability on real PDFs", .serialized)
@MainActor
struct DocumentFingerprintStabilityTests {
    @Test("the Merck fingerprint stays identical when the file is opened several times")
    func merckFingerprintStableAcrossReopens() throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: Merck PDF not found at \(TestPDFs.merck.path)")
            return
        }
        var fingerprints: Set<String> = []
        for _ in 0 ..< 5 {
            let document = try #require(PDFDocument(url: TestPDFs.merck))
            fingerprints.insert(DocumentFingerprint.compute(for: document))
        }
        #expect(fingerprints.count == 1, "different fingerprints across successive opens of the same file: \(fingerprints)")

        let data = try Data(contentsOf: TestPDFs.merck)
        let pageCount = try #require(PDFDocument(data: data)).pageCount
        let batched = try #require(DocumentFingerprint.computeBatched(
            data: data,
            expectedPageCount: pageCount,
            batchSize: 6
        ))
        #expect(batched == fingerprints.first)
    }

    @Test("the Draghi fingerprint stays identical when the file is opened several times")
    func draghiFingerprintStableAcrossReopens() throws {
        guard TestPDFs.ensureAvailable(TestPDFs.draghi) else {
            print("SKIP: Draghi PDF not found at \(TestPDFs.draghi.path)")
            return
        }
        var fingerprints: Set<String> = []
        for _ in 0 ..< 5 {
            let document = try #require(PDFDocument(url: TestPDFs.draghi))
            fingerprints.insert(DocumentFingerprint.compute(for: document))
        }
        #expect(fingerprints.count == 1, "different fingerprints across successive opens of the same file: \(fingerprints)")

        let data = try Data(contentsOf: TestPDFs.draghi)
        let pageCount = try #require(PDFDocument(data: data)).pageCount
        let batched = try #require(DocumentFingerprint.computeBatched(
            data: data,
            expectedPageCount: pageCount,
            batchSize: 6
        ))
        #expect(batched == fingerprints.first)
    }
}
}
