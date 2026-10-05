import Foundation
import Testing
@testable import LelePdf

@Suite("Chat context")
struct ChatContextTests {
    private let template = """
    T={{DOCUMENT_TITLE}}
    I={{TOC}}
    G={{GLOSSARY}}
    M={{MEMORY}}
    S={{SCOPE_DESCRIPTION}}
    R={{SEARCH_INSTRUCTIONS}}
    C={{DOCUMENT_CONTENT}}
    """

    private func snapshot(pageLength: Int = 20, current: Int = 4) -> ChatDocumentSnapshot {
        ChatDocumentSnapshot(
            title: "Documento",
            fingerprint: "abc123",
            pageTexts: (0 ..< 12).map { "TESTO-PAGINA-\($0 + 1) " + String(repeating: "x", count: pageLength) },
            toc: [
                ChatTOCEntry(title: "Capitolo 1", level: 1, page: 0),
                ChatTOCEntry(title: "Sezione 1.1", level: 2, page: 2),
                ChatTOCEntry(title: "Sottosezione 1.1.1", level: 3, page: 4),
                ChatTOCEntry(title: "Sezione 1.2", level: 2, page: 6),
                ChatTOCEntry(title: "Capitolo 2", level: 1, page: 8),
            ],
            glossary: ["- Termine (rectangle)"],
            analyzedSummaries: ["Riassunto [p. 2]"],
            currentPageIndex: current,
            visiblePageRange: 4...5
        )
    }

    @Test("visible pages include one page before and one after")
    func visiblePagesPlusOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plan = try ChatContextBuilder.build(
            snapshot: snapshot(), scope: .visiblePages, memory: nil, cacheRoot: root, template: template
        )
        #expect(plan.includedPages == 3...6)
        #expect(plan.systemPrompt.contains("TESTO-PAGINA-4"))
        #expect(plan.systemPrompt.contains("TESTO-PAGINA-7"))
        #expect(!plan.systemPrompt.contains("TESTO-PAGINA-3 "))
    }

    @Test("section and chapter follow the hierarchical boundaries of the contents")
    func hierarchyBoundaries() throws {
        let root = FileManager.default.temporaryDirectory
        let section = try ChatContextBuilder.build(
            snapshot: snapshot(), scope: .section, memory: nil, cacheRoot: root, template: template
        )
        let chapter = try ChatContextBuilder.build(
            snapshot: snapshot(), scope: .chapter, memory: nil, cacheRoot: root, template: template
        )
        #expect(section.includedPages == 4...5)
        #expect(chapter.includedPages == 0...7)
    }

    @Test("whole PDF contains title, contents, glossary, memory and 1-based pages")
    func fullPromptFields() throws {
        let plan = try ChatContextBuilder.build(
            snapshot: snapshot(), scope: .wholeDocument, memory: "Memoria test [p. 2]",
            cacheRoot: FileManager.default.temporaryDirectory, template: template
        )
        #expect(plan.includedPages == 0...11)
        #expect(plan.systemPrompt.contains("T=Documento"))
        #expect(plan.systemPrompt.contains("Capitolo 1 [p. 1]"))
        #expect(plan.systemPrompt.contains("Termine (rectangle)"))
        #expect(plan.systemPrompt.contains("Memoria test [p. 2]"))
        #expect(plan.systemPrompt.contains("--- p. 12 ---"))
        #expect(plan.estimatedTokens == ChatContextBuilder.estimate(plan.systemPrompt.components(separatedBy: "C=").last ?? ""))
    }

    @Test("over 100k tokens uses search mode and writes one clean file per page (with search re-enabled)")
    func searchModeWritesPages() throws {
        // Off by default in production: re-enabled only here so the search
        // mode construction itself keeps being verified, correct and ready
        // for when it is re-confirmed.
        let previous = ChatSearchPolicy.isEnabled
        ChatSearchPolicy.isEnabled = true
        defer { ChatSearchPolicy.isEnabled = previous }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lelepdf-chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try ChatContextBuilder.build(
            snapshot: snapshot(pageLength: 34_000), scope: .wholeDocument,
            memory: nil, cacheRoot: root, template: template
        )
        guard case .search(let directory, let allowedTools) = plan.mode else {
            Issue.record("expected search mode")
            return
        }
        #expect(allowedTools == ["Read(./**)", "Grep(./**)", "Glob(./**)"])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("p-0001.txt").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("p-0012.txt").path))
        let first = try String(contentsOf: directory.appendingPathComponent("p-0001.txt"), encoding: .utf8)
        #expect(first.contains("Page 1"))
        #expect(first.contains("TESTO-PAGINA-1"))
        #expect(plan.systemPrompt.contains("Riassunto [p. 2]"))
        #expect(!plan.systemPrompt.contains(String(repeating: "x", count: 1_000)))
    }

    @Test("search off by default: over 100k tokens throws a clear error, no file written")
    func searchDisabledByDefaultThrows() throws {
        #expect(ChatSearchPolicy.isEnabled == false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lelepdf-chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ChatContextError.searchDisabled) {
            try ChatContextBuilder.build(
                snapshot: snapshot(pageLength: 34_000), scope: .wholeDocument,
                memory: nil, cacheRoot: root, template: template
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(ChatContextError.searchDisabled.userMessage.contains("100 thousand"))
    }

    @Test("token estimate: about four characters per token")
    func tokenEstimate() {
        #expect(ChatContextBuilder.estimate(String(repeating: "a", count: 4_001)) == 1_001)
    }
}
