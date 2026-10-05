import AppKit
import Foundation
import Testing
@testable import LelePdf

/// Combined PDF + right-panel search: `DocumentModel.rewriteSearchBlockIds`/
/// `searchTotalCount`/`searchNext`/`searchPrevious`, the part that needs no
/// real `NSWindow` (the real focus of the field is covered in
/// `SearchFieldFocusTests`, `HeavyTestSuites`).
@MainActor
@Suite("DocumentModel · search", .serialized)
struct DocumentModelSearchTests {
    private func block(_ id: String, page: Int = 0, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id, words: 4, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    /// Two analyzed blocks: "b1" contains the query in the rewritten text,
    /// "b2" does not. The PDF itself contains the query once (for the PDF
    /// side of the combined count).
    private func makeModel(query: String = "gemma") throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Il documento parla di gemma preziosa una volta sola.", fileName: "search-combined-\(UUID().uuidString).pdf")
        let document = PDFFileDocument(data: try Data(contentsOf: sourceURL), displayName: "search-combined")
        let model = try #require(DocumentModel(document: document, fileURL: sourceURL))

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, rewrite: [RewriteItem(kind: .paragraph, text: "Questo blocco parla di \(query) preziosa.")], claudeRewrite: [])
        analysis.blocks["b2"] = BlockAnalysis(status: .analyzed, rewrite: [RewriteItem(kind: .paragraph, text: "Questo blocco non contiene la parola cercata.")], claudeRewrite: [])
        model.analysisController.updateContext(
            fingerprint: "fp-search-\(UUID().uuidString)", documentTitle: "T",
            blocks: [block("b1", page: 0, text: "gemma"), block("b2", page: 0, text: "altro")],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )
        return model
    }

    @Test("right-panel results are listed AFTER the PDF ones, one block = one result")
    func rewriteMatchesComeAfterPDFMatches() async throws {
        let model = try makeModel()
        model.searchQuery = "gemma"
        model.runSearch()
        // `runSearch` enqueues work on a `Task` with a small delay (150 ms):
        // the test waits generously for it to settle, the same scheme already
        // used to avoid depending on the debounce timing.
        try? await Task.sleep(for: .seconds(1.5))

        #expect(model.searchResults.count == 1, "the test PDF contains \"gemma\" only once")
        #expect(model.rewriteSearchBlockIds == ["b1"], "only b1 contains the query in the rewritten text")
        #expect(model.searchTotalCount == 2)
        #expect(model.currentSearchResultIndex == 0)
    }

    @Test("searchNext/searchPrevious step through the combined index, wrapping at the ends")
    func navigationWrapsAcrossCombinedResults() async throws {
        let model = try makeModel()
        model.searchQuery = "gemma"
        model.runSearch()
        try? await Task.sleep(for: .seconds(1.5))
        #expect(model.searchTotalCount == 2)

        model.searchNext()
        #expect(model.currentSearchResultIndex == 1) // the right-panel result

        model.searchNext()
        #expect(model.currentSearchResultIndex == 0) // wraps around to the PDF

        model.searchPrevious()
        #expect(model.currentSearchResultIndex == 1)
    }

    @Test("closeSearch: clears query/results (PDF and panel), no crash on empty results")
    func closeSearchClearsEverything() async throws {
        let model = try makeModel()
        model.searchQuery = "gemma"
        model.runSearch()
        try? await Task.sleep(for: .seconds(1.5))
        #expect(model.searchTotalCount == 2)

        model.closeSearch()
        #expect(model.searchQuery.isEmpty)
        #expect(model.searchResults.isEmpty)
        #expect(model.rewriteSearchBlockIds.isEmpty)
        #expect(model.currentSearchResultIndex == nil)
        #expect(model.searchTotalCount == 0)

        model.searchNext() // must do nothing / must not crash
        #expect(model.currentSearchResultIndex == nil)
    }

    @Test("isSearchAvailable: false while a right-panel line is being edited in place")
    func searchUnavailableWhileEditingLine() async throws {
        let model = try makeModel()
        #expect(model.isSearchAvailable)
        model.analysisController.beginEditingLine(blockId: "b1")
        #expect(model.isSearchAvailable == false)
        let tokenBefore = model.searchFocusToken
        model.focusSearch() // must be a no-op while editing
        #expect(model.searchFocusToken == tokenBefore)
        model.analysisController.endEditingLine(blockId: "b1")
        #expect(model.isSearchAvailable)
    }

    @Test("empty query: no PDF or panel results, PDF highlighting off")
    func emptyQueryClearsResults() async throws {
        let model = try makeModel()
        model.searchQuery = "gemma"
        model.runSearch()
        try? await Task.sleep(for: .seconds(1.5))
        #expect(model.searchTotalCount == 2)

        model.searchQuery = ""
        model.runSearch()
        #expect(model.searchResults.isEmpty)
        #expect(model.rewriteSearchBlockIds.isEmpty)
        #expect(model.currentSearchResultIndex == nil)
    }
}
