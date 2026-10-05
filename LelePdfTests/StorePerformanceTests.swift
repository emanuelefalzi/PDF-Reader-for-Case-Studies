import Testing
import Foundation
@testable import LelePdf

/// Measures the Store's fast path (SPEC §9 "Saved data visible within 1 s of
/// the first page"): hash of the file bytes plus index lookup, on the real
/// Merck case. It does not include the pipeline (that is measured in
/// `TextPipelineIntegrationTests`, M2): the fast path exists precisely so as
/// not to wait for it when the document is already known.
extension HeavyTestSuites {
@Suite("Store · fast path performance")
struct StorePerformanceTests {
    @Test("byte hash + index lookup for the Merck case: under 1 s")
    func fastPathUnderOneSecond() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found at \(TestPDFs.merck.path)")
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfStorePerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = DocumentStore(dataFolderURL: dir)
        let byteHash = try #require(DocumentStore.hashFileBytes(at: TestPDFs.merck))
        _ = await store.registerDocument(fingerprint: "fp-merck-perf", byteHash: byteHash, fileName: "merck.pdf", lastKnownPath: TestPDFs.merck.path, title: "Merck", pageCount: 37)
        await store.flush(fingerprint: "fp-merck-perf")

        // From here on, like a reopen: only hash + lookup, without waiting
        // for the pipeline.
        let start = Date()
        let result = await store.fastLookup(fileURL: TestPDFs.merck)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.record != nil)
        #expect(elapsed < 1.0)
        print("MEASURE fast path (Merck, hash + index lookup): \(String(format: "%.3f", elapsed)) s")
    }
}
}
