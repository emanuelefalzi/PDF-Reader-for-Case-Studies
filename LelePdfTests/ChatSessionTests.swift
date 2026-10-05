import Foundation
import Testing
@testable import LelePdf

/// `ChatSession`/`ChatProcessIO` (SPEC §7.8): lifecycle of the persistent
/// `stream-json` process. The chat UI is covered elsewhere; here only the
/// process level is verified. `.timeLimit` makes a test fail quickly if a
/// future change left the stream open forever, instead of blocking the whole
/// suite.
@Suite("ChatSession", .timeLimit(.minutes(1)))
struct ChatSessionTests {
    private func collectUntilResult(_ iterator: inout AsyncStream<ChatEvent>.Iterator) async -> [ChatEvent] {
        var events: [ChatEvent] = []
        while let event = await iterator.next() {
            events.append(event)
            if case .result = event { break }
        }
        return events
    }

    private func expectedReply(for userText: String) -> String {
        "Risposta alla domanda: \"\(String(userText.prefix(40)))\". "
            + "Il documento lo spiega [p. 3] con chiarezza. "
            + "<fuori>Questa parte viene da conoscenza esterna, non dal PDF.</fuori> "
            + "Vedi anche [p. 12] per un approfondimento."
    }

    @Test("start() emits systemInit with the requested model")
    func startEmitsSystemInit() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let session = ChatSession()
            let stream = await session.start(model: .sonnet, systemPrompt: "sistema di prova")
            var iterator = stream.makeAsyncIterator()
            guard case .systemInit(let model, _) = await iterator.next() else {
                Issue.record("expected systemInit as the first event")
                await session.stop()
                return
            }
            #expect(model == "sonnet")
            await session.stop()
        }
    }

    @Test("two messages in sequence: textDelta, assistantMessage, result with usage")
    func twoMessagesStreamedWithUsage() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let session = ChatSession()
            let stream = await session.start(model: .sonnet, systemPrompt: "sistema di prova")
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next() // systemInit

            for userText in ["Prima domanda", "Seconda domanda, diversa dalla prima"] {
                await session.send(userText)
                let events = await collectUntilResult(&iterator)
                let expected = expectedReply(for: userText)

                #expect(events.contains { if case .textDelta = $0 { return true }; return false })
                #expect(events.contains(.assistantMessage(expected)))
                guard case .result(let usage, let text, let isError) = events.last else {
                    Issue.record("expected result as the last event of the exchange, found \(String(describing: events.last))")
                    continue
                }
                #expect(text == expected)
                #expect(!isError)
                #expect(usage == ClaudeUsage(inputTokens: 120, cacheCreationInputTokens: 3400, cacheReadInputTokens: 0, outputTokens: 640))
            }
            await session.stop()
        }
    }

    private func lastRateLimit(_ events: [ChatEvent]) -> RateLimitInfo? {
        for event in events { if case .rateLimit(let info) = event { return info } }
        return nil
    }

    @Test("rate_limit mode: nested rate_limit_event (real format) and result with isError")
    func rateLimitEventSurfaced() async throws {
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "rate_limit",
        ]) {
            let session = ChatSession()
            let stream = await session.start(model: .sonnet, systemPrompt: "sistema di prova")
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next() // systemInit

            await session.send("Una domanda qualsiasi")
            let events = await collectUntilResult(&iterator)

            // The fake CLI generates "now + 1 h": see the comment on
            // rate_limit_message() in scripts/fake-claude/claude.
            guard let info = lastRateLimit(events), let resetsAt = info.resetsAt else {
                Issue.record("expected a rateLimit event with a reset date")
                await session.stop()
                return
            }
            #expect(info.status == "rejected")
            #expect(abs(resetsAt.timeIntervalSinceNow - 3600) < 30)
            #expect(info.fiveHour?.utilization == 1.0)
            guard case .result(_, _, let isError) = events.last else {
                Issue.record("expected result as the last event")
                await session.stop()
                return
            }
            #expect(isError)
            await session.stop()
        }
    }

    @Test("a successful turn still carries an \"allowed\" rate_limit_event at low usage")
    func allowedRateLimitEventOnNormalTurn() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let session = ChatSession()
            let stream = await session.start(model: .sonnet, systemPrompt: "sistema di prova")
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next() // systemInit

            await session.send("Domanda normale")
            let events = await collectUntilResult(&iterator)

            guard let info = lastRateLimit(events) else {
                Issue.record("expected a rateLimit event even on a successful turn")
                await session.stop()
                return
            }
            #expect(info.status == "allowed")
            #expect(info.fiveHour?.utilization == 0.27)
            #expect(info.sevenDay?.utilization == 0.37)
            await session.stop()
        }
    }

    @Test("the legacy format (top-level keys, no rate_limit_info) is still parsed")
    func legacyRateLimitFormatStillParsed() async throws {
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "rate_limit_legacy",
        ]) {
            let session = ChatSession()
            let stream = await session.start(model: .sonnet, systemPrompt: "sistema di prova")
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next() // systemInit

            await session.send("Una domanda qualsiasi")
            let events = await collectUntilResult(&iterator)

            guard let info = lastRateLimit(events) else {
                Issue.record("expected a rateLimit event in the legacy format too")
                await session.stop()
                return
            }
            #expect(info.status == "rejected")
            #expect(info.resetsAt != nil)
            #expect(info.fiveHour == nil, "the legacy format has no unifiedWindows")
            await session.stop()
        }
    }

    @Test("stop() closes the stream without hanging")
    func stopFinishesStreamPromptly() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let session = ChatSession()
            let stream = await session.start(model: .sonnet, systemPrompt: "sistema di prova")
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next() // systemInit

            let start = Date()
            await session.stop()
            #expect(Date().timeIntervalSince(start) < 3, "stop() must not blindly wait out the 2 s grace period if the process is already dead")

            var remaining = 0
            while await iterator.next() != nil { remaining += 1 }
            #expect(remaining <= 1, "at most one leftover processExited, then the stream must end")
        }
    }

    @Test("a short idle timeout stops the session on its own, with no sends or explicit stop")
    func shortIdleTimeoutStopsSession() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let session = ChatSession(idleTimeout: 0.3)
            let stream = await session.start(model: .sonnet, systemPrompt: "sistema di prova")
            var eventCount = 0
            for await _ in stream { eventCount += 1 }
            // The mere fact that the `for await` loop terminates confirms the
            // stream closed on its own: no send, no explicit stop, only the
            // idle timeout (SPEC §7.8 "10 minutes").
            #expect(eventCount >= 1)
        }
    }

    @Test("the search scope passes the expected arguments (SPEC §7.8.1, plumbing)")
    func searchModePassesExpectedArguments() async throws {
        let logPath = makeTempFilePath("chat-search-log.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let workingDirectory = FileManager.default.temporaryDirectory
            let session = ChatSession()
            let stream = await session.start(
                model: .sonnet, systemPrompt: "sistema di ricerca",
                mode: .search(workingDirectory: workingDirectory, allowedTools: ["Read", "Grep"])
            )
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next() // systemInit
            await session.stop()

            let entries = readFakeClaudeLog(logPath)
            let entry = try #require(entries.last)
            let argv = try #require(entry["argv"] as? [String])
            #expect(argv.contains("Read,Grep,Glob"))
            let allowedIndex = try #require(argv.firstIndex(of: "--allowedTools"))
            #expect(Array(argv[(allowedIndex + 1)...(allowedIndex + 2)]) == ["Read", "Grep"])
            #expect(argv.filter { $0 == "--allowedTools" }.count == 1)
            #expect(argv.contains("--permission-mode"))
            #expect(argv.contains("dontAsk"))
            let cwd = try #require(entry["cwd"] as? String)
            #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == workingDirectory.resolvingSymlinksInPath().path)
        }
    }

    @Test("normal mode disables the tools and prefixes the visible pages")
    func normalArgumentsAndVisiblePagePrefix() async throws {
        let logPath = makeTempFilePath("chat-normal-log.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let session = ChatSession()
            let stream = await session.start(model: .opus, systemPrompt: "prompt normale")
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            await session.send("Perché?", visiblePageRange: "Visible pages: 4-5")
            _ = await collectUntilResult(&iterator)
            await session.stop()

            let records = readFakeClaudeLog(logPath)
            let invocation = try #require(records.first { ($0["argv"] as? [String])?.contains("stream-json") == true })
            let argv = try #require(invocation["argv"] as? [String])
            let toolsIndex = try #require(argv.firstIndex(of: "--tools"))
            #expect(argv.indices.contains(toolsIndex + 1))
            #expect(argv[toolsIndex + 1].isEmpty)
            #expect(argv.contains("opus"))
            let input = try #require(records.first { $0["event"] as? String == "chat_input" }?["text"] as? String)
            #expect(input == "[Visible pages: 4-5] Perché?")
        }
    }
}
