import CryptoKit
import Foundation
@preconcurrency import PDFKit

/// Document fingerprint (SPEC §8): SHA-256 of the page count plus the text
/// of all pages. It survives renaming, moving and metadata-only changes. The
/// pure part is testable without PDFKit; text extraction stays on the
/// MainActor (M3 will also use it for the fingerprint index).
enum DocumentFingerprint {
    static func compute(pageCount: Int, pageTexts: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(String(pageCount).utf8))
        for text in pageTexts {
            hasher.update(data: Data(text.utf8))
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// [M5b fix, found during visual verification with real data]: on a real
    /// PDF that has just been opened, `PDFPage.string` can come back empty or
    /// incomplete the very first time it is read on a page not yet
    /// "materialized" by PDFKit (a known behavior, undocumented by Apple, of
    /// content-stream parsing still in progress): the fingerprint computed on
    /// that first pass turned out different from one session to the next for
    /// the exact same file (same byte hash, different content fingerprint;
    /// observed when reopening the real Merck case after some real analyses:
    /// a new data folder was created and the saved analyses were "lost" until
    /// the old folder). `LineExtractor`, which also reads `page.string` but
    /// only page by page later in the pipeline (after this same reading pass
    /// has already "warmed up" PDFKit), never showed the same symptom,
    /// consistent with this cause. Fix: a first read-only pass (discarded)
    /// before the real one, so the fingerprint is computed only when every
    /// page has already been touched at least once.
    @MainActor
    static func compute(for document: PDFDocument) -> String {
        for index in 0 ..< document.pageCount {
            _ = document.page(at: index)?.string
        }
        var texts: [String] = []
        texts.reserveCapacity(document.pageCount)
        for index in 0 ..< document.pageCount {
            texts.append(document.page(at: index)?.string ?? "")
        }
        return compute(pageCount: document.pageCount, pageTexts: texts)
    }

    /// Memory-bounded variant used by the app's pipeline. Each batch is read
    /// from an ephemeral `PDFDocument`, separate from the one shown in the
    /// `PDFView`: PDFKit can thus destroy its per-character caches when the
    /// `autoreleasepool` ends, instead of holding them for all pages as long
    /// as the window stays open.
    ///
    /// The first warm-up pass is deliberately kept in EVERY batch: it
    /// preserves the M5b fix documented above even though each batch uses a
    /// new `PDFDocument` instance. The hash is fed immediately and in page
    /// order, so it does not hold the text of the whole document.
    @MainActor
    static func computeBatched(data: Data, expectedPageCount: Int, batchSize: Int) -> String? {
        guard expectedPageCount >= 0, batchSize > 0 else { return nil }

        var hasher = SHA256()
        hasher.update(data: Data(String(expectedPageCount).utf8))

        for lowerBound in stride(from: 0, to: expectedPageCount, by: batchSize) {
            let upperBound = min(lowerBound + batchSize, expectedPageCount)
            let succeeded = autoreleasepool { () -> Bool in
                guard let document = PDFDocument(data: data), document.pageCount == expectedPageCount else {
                    return false
                }
                for pageIndex in lowerBound ..< upperBound {
                    _ = document.page(at: pageIndex)?.string
                }
                for pageIndex in lowerBound ..< upperBound {
                    let text = document.page(at: pageIndex)?.string ?? ""
                    hasher.update(data: Data(text.utf8))
                }
                return true
            }
            guard succeeded else { return nil }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
