import Foundation
@preconcurrency import PDFKit

@MainActor
extension DocumentModel {
    func chatSnapshot() -> ChatDocumentSnapshot {
        let pageTexts: [String]
        if let structure {
            pageTexts = Self.cleanPageTexts(from: structure)
        } else {
            pageTexts = (0 ..< pageCount).map { pdfDocument.page(at: $0)?.string ?? "" }
        }
        let toc = tocEntries.map { ChatTOCEntry(title: $0.title, level: $0.level, page: $0.page) }
        let glossary = (analysis?.terms.values ?? Dictionary<String, TermRecord>().values)
            .sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
            .map { "- \($0.term) (\($0.type.rawValue))" }
        let blockByID = Dictionary(uniqueKeysWithValues: (structure?.blocks ?? []).map { ($0.id, $0) })
        let summaries = (analysis?.blocks ?? [:]).compactMap { id, block -> (Int, String)? in
            guard block.status == .analyzed else { return nil }
            let page = blockByID[id]?.pageStart ?? block.marks.first?.page ?? 0
            let body = RewritePlainText.render(block.rewrite)
            guard !body.isEmpty else { return nil }
            return (page, "### \(block.title ?? "Block") [p. \(page + 1)]\n\(body)")
        }.sorted { $0.0 < $1.0 }.map(\.1)
        let fingerprint = structure?.fingerprint
            ?? documentRecord?.fingerprint
            ?? LastPageStore.provisionalKey(for: sourceData)
        let safeVisible = visiblePageRange.clamped(to: 0 ... max(0, pageCount - 1))
        return ChatDocumentSnapshot(
            title: documentRecord?.title ?? displayName,
            fingerprint: fingerprint,
            pageTexts: pageTexts,
            toc: toc,
            glossary: glossary,
            analyzedSummaries: summaries,
            currentPageIndex: currentPageIndex,
            visiblePageRange: safeVisible
        )
    }

    func toggleChat() {
        chatController.toggle(snapshot: chatSnapshot())
    }

    /// Used by the chat chips and reusable by clicks on the concept map: the
    /// PDF jumps to the page and the sync coordinator scrolls the right-hand
    /// panel to the matching row, even with "Follow the PDF" turned off.
    func navigateFromChatCitation(pageNumber: Int) {
        let index = pageNumber - 1
        guard index >= 0, index < pageCount else { return }
        goToPage(index)
        syncCoordinator.handlePageNavigation(pageIndex: index)
    }

    private static func cleanPageTexts(from structure: DocumentStructure) -> [String] {
        var fragments = [[String]](repeating: [], count: structure.pageCount)
        for block in structure.blocks {
            for span in block.spans where fragments.indices.contains(span.page) {
                let characters = Array(block.cleanText)
                let lower = min(max(0, span.cleanStart), characters.count)
                let upper = min(max(lower, span.cleanStart + span.cleanLength), characters.count)
                guard lower < upper else { continue }
                fragments[span.page].append(String(characters[lower ..< upper]))
            }
        }
        return fragments.map { $0.joined(separator: "\n\n") }
    }
}
