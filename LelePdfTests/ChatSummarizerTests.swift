import Foundation
import Testing
@testable import LelePdf

/// The default summary provider of `ChatController` (SPEC §7.8.2
/// "Summarise & continue"): all `ChatControllerTests` inject a test
/// `summaryProvider`, so this path (the real one-shot call made by
/// `ChatSummarizer.summarize`) was never exercised by the suite with the
/// fake CLI.
@Suite("Chat summarizer")
struct ChatSummarizerTests {
    @Test("one-shot summary: correct prompt, no schema, text from the fake CLI")
    func summarizeCallsOneShotWithoutSchema() async throws {
        let logPath = makeTempFilePath("chat-summarizer-log.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let messages = [
                ChatMessage(role: .user, rawText: "Domanda di prova"),
                ChatMessage(role: .assistant, rawText: "Risposta [p. 3]"),
            ]
            let summary = await ChatSummarizer.summarize(messages, model: .sonnet)
            let text = try #require(summary)
            #expect(!text.isEmpty)

            let entries = readFakeClaudeLog(logPath)
            let invocation = try #require(entries.first { ($0["argv"] as? [String])?.contains("-p") == true })
            let argv = try #require(invocation["argv"] as? [String])
            #expect(!argv.contains("--json-schema"))
            #expect(argv.contains("--output-format"))
            #expect(argv.contains { $0.contains("Domanda di prova") })
        }
    }

    @Test("no conversation: returns nil without calling the CLI")
    func emptyTranscriptSkipsCall() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let summary = await ChatSummarizer.summarize([ChatMessage(role: .note, rawText: "nota")])
            #expect(summary == nil)
        }
    }
}
