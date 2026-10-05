import Foundation
import Testing
@preconcurrency import PDFKit
@testable import LelePdf

/// For 3 pages of each test PDF, `page.selection(for:).string` must match
/// the same substring of `page.string`, for ranges derived from the real
/// blocks' spans (SPEC §7.3, last point). Whitespace is normalized before
/// the comparison: PDFKit sometimes inserts line breaks where `page.string`
/// has a plain space, or vice versa (observed during development).
extension HeavyTestSuites {
@Suite("Pipeline · PDFKit selections from blocks", .serialized)
@MainActor
struct BlockSelectionRoundTripTests {
    @Test("Draghi: selections of 3 pages match page.string")
    func draghiSelections() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.draghi) else {
            print("SKIP: Draghi PDF not found at \(TestPDFs.draghi.path)")
            return
        }
        try await assertSelectionsMatch(url: TestPDFs.draghi)
    }

    @Test("Merck: selections of 3 pages match page.string")
    func merckSelections() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: Merck PDF not found at \(TestPDFs.merck.path)")
            return
        }
        try await assertSelectionsMatch(url: TestPDFs.merck)
    }

    private func assertSelectionsMatch(url: URL) async throws {
        let document = try #require(PDFDocument(url: url))
        let result = await PipelineRealDocumentHelper.run(document)

        var checkedPages = Set<Int>()
        var checks = 0
        for block in result.output.blocks {
            for span in block.spans {
                guard !checkedPages.contains(span.page), let page = document.page(at: span.page),
                      let minOrig = span.charMap.min(), let maxOrig = span.charMap.max()
                else { continue }
                checkedPages.insert(span.page)

                let range = NSRange(location: minOrig, length: maxOrig - minOrig + 1)
                let fullString = (page.string ?? "") as NSString
                guard range.location >= 0, range.location + range.length <= fullString.length else { continue }

                let expected = fullString.substring(with: range)
                let selectionString = page.selection(for: range)?.string ?? ""
                #expect(normalize(selectionString) == normalize(expected), "page \(span.page)")
                checks += 1
                if checkedPages.count >= 3 { break }
            }
            if checkedPages.count >= 3 { break }
        }
        #expect(checks >= 1, "no page checked for \(url.lastPathComponent)")
    }

    private func normalize(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
}
