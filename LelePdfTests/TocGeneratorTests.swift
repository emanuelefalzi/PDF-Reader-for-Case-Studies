import Foundation
import Testing
@testable import LelePdf

/// `TocGenerator` (SPEC §7.4, M4 item 8): prompt building (pure), validation
/// (pure) and a real call through `BatchRunner` + the fake CLI.
@Suite("TocGenerator")
struct TocGeneratorTests {
    private func candidate(title: String, page: Int, levelHint: Int = 1, source: TocCandidateSource = .heading, following: String = "testo di esempio che segue il titolo") -> TocCandidate {
        TocCandidate(title: title, page: page, levelHint: levelHint, source: source, followingWords: following)
    }

    // MARK: - buildPrompt (pure)

    @Test("the prompt uses 1-based pages and reports title/pages/provenance labels")
    func buildPromptUsesOneBasedPagesAndSourceLabels() {
        let candidates = [
            candidate(title: "Chapter 1", page: 0, levelHint: 1, source: .heading),
            candidate(title: "Introduzione", page: 4, levelHint: 2, source: .runningHeader),
        ]
        let prompt = TocGenerator.buildPrompt(title: "Documento di prova", pageCount: 73, candidates: candidates)

        #expect(prompt.contains("Document: Documento di prova"))
        #expect(prompt.contains("Total pages: 73"))
        #expect(prompt.contains("p.1 [suggested level 1, title]: \"Chapter 1\""))
        #expect(prompt.contains("p.5 [suggested level 2, repeated running header]: \"Introduzione\""))
    }

    @Test("a candidate with no following words uses the (none) placeholder")
    func buildPromptHandlesEmptyFollowingWords() {
        let prompt = TocGenerator.buildPrompt(title: "T", pageCount: 10, candidates: [candidate(title: "X", page: 0, following: "")])
        #expect(prompt.contains("followed by: (none)"))
    }

    // MARK: - validate (pure)

    @Test("valid entries are sorted by page")
    func validateSortsByPage() throws {
        let entries = [
            GeneratedTocEntry(title: "Capitolo 2", level: 1, page: 8),
            GeneratedTocEntry(title: "Capitolo 1", level: 1, page: 1),
        ]
        let sorted = try #require(try? TocGenerator.validate(entries, pageCount: 10).get())
        #expect(sorted.map(\.title) == ["Capitolo 1", "Capitolo 2"])
    }

    @Test("a level outside 1-3 is rejected")
    func validateRejectsLevelOutOfRange() {
        let entries = [GeneratedTocEntry(title: "X", level: 4, page: 1)]
        let result = TocGenerator.validate(entries, pageCount: 10)
        #expect(result.isFailure)
    }

    @Test("a page outside the document is rejected")
    func validateRejectsPageOutOfRange() {
        let entries = [GeneratedTocEntry(title: "X", level: 1, page: 999)]
        let result = TocGenerator.validate(entries, pageCount: 10)
        #expect(result.isFailure)
    }

    @Test("an empty title is rejected")
    func validateRejectsEmptyTitle() {
        let entries = [GeneratedTocEntry(title: "   ", level: 1, page: 1)]
        let result = TocGenerator.validate(entries, pageCount: 10)
        #expect(result.isFailure)
    }

    @Test("no entries is rejected")
    func validateRejectsEmptyEntries() {
        let result = TocGenerator.validate([], pageCount: 10)
        #expect(result.isFailure)
    }

    // MARK: - generate (fake CLI)

    @Test("no candidates: immediate success, empty entries, no call")
    func generateWithNoCandidatesSkipsCall() async throws {
        let logPath = makeTempFilePath("toc-no-candidates.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let outcome = await TocGenerator.generate(title: "T", pageCount: 10, candidates: [])
            let value = try #require(try? outcome.get())
            #expect(value.value.isEmpty)
            #expect(readFakeClaudeLog(logPath).isEmpty)
        }
    }

    @Test("success: the fake CLI mirrors the candidates sent, validated and sorted")
    func generateSuccessReflectsCandidates() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let candidates = [
                candidate(title: "Chapter 1", page: 0, levelHint: 1),
                candidate(title: "Chapter 2", page: 7, levelHint: 1),
                candidate(title: "1.1 Contesto", page: 1, levelHint: 2),
            ]
            let outcome = await TocGenerator.generate(title: "Documento di prova", pageCount: 50, candidates: candidates)
            let value = try #require(try? outcome.get())
            #expect(Set(value.value.map(\.title)) == Set(["Chapter 1", "Chapter 2", "1.1 Contesto"]))
            #expect(value.value == value.value.sorted { $0.page < $1.page })
            for entry in value.value { #expect((1...50).contains(entry.page)) }
        }
    }

    @Test("invalid entries (page out of range) return invalidEntries")
    func generateInvalidEntriesReturnsError() async throws {
        let responsePath = makeTempFilePath("toc-invalid-response.json")
        try #"{"entries":[{"title":"Fuori range","level":1,"page":9999}]}"#.write(toFile: responsePath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: responsePath) }

        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_RESPONSE_FILE": responsePath,
        ]) {
            let outcome = await TocGenerator.generate(title: "T", pageCount: 10, candidates: [candidate(title: "X", page: 0)])
            guard case .failure(.invalidEntries) = outcome else {
                Issue.record("expected .invalidEntries, found \(outcome)")
                return
            }
        }
    }

    @Test("an error from the Claude layer propagates as .claude(...)")
    func generateClaudeErrorPropagates() async throws {
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "not_logged_in",
        ]) {
            let outcome = await TocGenerator.generate(title: "T", pageCount: 10, candidates: [candidate(title: "X", page: 0)])
            #expect(outcome == .failure(.claude(.notLoggedIn)))
        }
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
