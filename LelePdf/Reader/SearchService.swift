import Foundation
@preconcurrency import PDFKit

/// PDF search (SPEC §5.10), used both by the UI (`SearchBar`,
/// `DocumentModel`) and by the integration tests: same function, same
/// behavior. It stays on the MainActor like all of PDFKit; `find` is a
/// single fast synchronous call on the test documents, so the interface
/// stays responsive by calling it from a `Task` with a small delay (see
/// `DocumentModel.runSearch`), not from here.
@MainActor
enum SearchService {
    /// Searches `query` in the document, filtering by `pageRange` when given
    /// ("Chapter" scope); `nil` = the whole PDF. Known limit (SPEC §5.10): a
    /// word split at a line break may not be found, because `findString`
    /// works on the page's raw text.
    static func find(_ query: String, in document: PDFDocument, pageRange: ClosedRange<Int>?) -> [PDFSelection] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let allResults = document.findString(query, withOptions: [.caseInsensitive])
        guard let pageRange else { return allResults }
        return allResults.filter { selection in
            guard let page = selection.pages.first else { return false }
            let index = document.index(for: page)
            return index != NSNotFound && pageRange.contains(index)
        }
    }
}
