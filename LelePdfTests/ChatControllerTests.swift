import Foundation
import Testing
@testable import LelePdf

private actor SummaryProbe {
    private(set) var calls = 0
    func run(_ messages: [ChatMessage]) -> String {
        calls += 1
        return "MEMORIA TEST con citazione [p. 3]"
    }
}

@MainActor
@Suite("Chat controller", .serialized, .timeLimit(.minutes(1)))
struct ChatControllerTests {
    private func snapshot(current: Int = 2) -> ChatDocumentSnapshot {
        ChatDocumentSnapshot(
            title: "Documento test", fingerprint: "fake-chat",
            pageTexts: (1...15).map { "Testo pulito della pagina \($0)." },
            toc: [
                ChatTOCEntry(title: "Capitolo 1", level: 1, page: 0),
                ChatTOCEntry(title: "Capitolo 2", level: 1, page: 8),
            ],
            glossary: [], analyzedSummaries: [], currentPageIndex: current,
            visiblePageRange: current...current
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    @Test("streaming yields text, page chip, external and Go to point")
    func streamingSegments() async throws {
        try await withClaudeMainActorTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let controller = ChatController(cacheRoot: FileManager.default.temporaryDirectory)
            controller.open(snapshot: snapshot())
            controller.inputText = "Qual è la risposta?"
            controller.submit(snapshot: snapshot())
            #expect(await waitUntil { !controller.isResponding && controller.messages.contains { $0.role == .assistant } })
            let answer = try #require(controller.messages.last(where: { $0.role == .assistant }))
            #expect(answer.segments.contains(.citation(label: "[p. 3]", page: 3)))
            #expect(answer.segments.contains { if case .external(let text) = $0 { return text.contains("conoscenza esterna") }; return false })
            #expect(answer.firstCitationPage == 3)
            await controller.closeWindow()
        }
    }

    @Test("a result without deltas stays visible and is parsed")
    func resultOnlyFallback() async throws {
        try await withClaudeMainActorTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "result_only",
        ]) {
            let controller = ChatController(cacheRoot: FileManager.default.temporaryDirectory)
            controller.open(snapshot: snapshot())
            controller.inputText = "Risposta finale"
            controller.submit(snapshot: snapshot())
            #expect(await waitUntil { !controller.isResponding && controller.messages.contains { $0.role == .assistant } })
            let answer = try #require(controller.messages.last(where: { $0.role == .assistant }))
            #expect(answer.segments.contains(.citation(label: "[p. 3]", page: 3)))
            #expect(!answer.rawText.isEmpty)
            await controller.closeWindow()
        }
    }

    @Test("scope change restarts, adds a note and carries the memory into the prompt")
    func scopeChangeRestartsWithSummary() async throws {
        let log = makeTempFilePath("chat-controller-scope.jsonl")
        defer { try? FileManager.default.removeItem(atPath: log) }
        let probe = SummaryProbe()
        try await withClaudeMainActorTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_LOG": log,
        ]) {
            let controller = ChatController(
                cacheRoot: FileManager.default.temporaryDirectory,
                summaryProvider: { messages in await probe.run(messages) }
            )
            controller.open(snapshot: snapshot())
            controller.inputText = "Prima"
            controller.submit(snapshot: snapshot())
            #expect(await waitUntil { !controller.isResponding && controller.messages.contains { $0.role == .assistant } })

            controller.scope = .wholeDocument
            controller.inputText = "Seconda"
            controller.submit(snapshot: snapshot())
            #expect(await waitUntil { !controller.isResponding && controller.messages.filter { $0.role == .assistant }.count == 2 })
            #expect(controller.messages.contains { $0.role == .note && $0.rawText.contains("Context changed") })
            #expect(await probe.calls == 1)

            let chatInvocations = readFakeClaudeLog(log).filter {
                let argv = $0["argv"] as? [String]
                return argv?.contains("stream-json") == true
            }
            #expect(chatInvocations.count == 2)
            let secondArguments = try #require(chatInvocations.last?["argv"] as? [String])
            #expect(secondArguments.contains { $0.contains("MEMORIA TEST") })
            await controller.closeWindow()
        }
    }

    @Test("at 85% summarizes automatically before the next question")
    func automaticSummary() async throws {
        let probe = SummaryProbe()
        await withClaudeMainActorTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let controller = ChatController(
                cacheRoot: FileManager.default.temporaryDirectory, budgetLimit: 4_000,
                summaryProvider: { messages in await probe.run(messages) }
            )
            controller.open(snapshot: snapshot())
            controller.inputText = "Prima"
            controller.submit(snapshot: snapshot())
            #expect(await waitUntil { !controller.isResponding && controller.budget.shouldAutoSummarize })
            controller.inputText = "Dopo il riassunto"
            controller.submit(snapshot: snapshot())
            #expect(await waitUntil { !controller.isResponding && controller.messages.filter { $0.role == .assistant }.count == 2 })
            #expect(await probe.calls == 1)
            #expect(controller.messages.contains { $0.role == .divider && $0.rawText == "Conversation summarized" })
            await controller.closeWindow()
        }
    }

    @Test("green, orange and red ring thresholds")
    func ringThresholds() {
        #expect(ChatBudget(usedTokens: 5_999, limit: 10_000).level == .green)
        #expect(ChatBudget(usedTokens: 6_000, limit: 10_000).level == .orange)
        #expect(ChatBudget(usedTokens: 8_500, limit: 10_000).level == .red)
    }

    @Test("closing the window stops the process")
    func windowCloseStopsProcess() async throws {
        await withClaudeMainActorTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let controller = ChatController(cacheRoot: FileManager.default.temporaryDirectory)
            controller.open(snapshot: snapshot())
            #expect(await waitUntil { await controller.processIsActiveForTesting() })
            await controller.closeWindow()
            #expect(!(await controller.processIsActiveForTesting()))
        }
    }

    @Test("closing immediately during startup does not launch a late process")
    func immediateWindowCloseCancelsStartup() async throws {
        await withClaudeMainActorTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let controller = ChatController(cacheRoot: FileManager.default.temporaryDirectory)
            controller.open(snapshot: snapshot())
            await controller.closeWindow()
            try? await Task.sleep(for: .milliseconds(300))
            #expect(!(await controller.processIsActiveForTesting()))
        }
    }

    @Test("opening a second window stops the first window's process")
    func singleProcessAcrossWindows() async throws {
        await withClaudeMainActorTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let first = ChatController(cacheRoot: FileManager.default.temporaryDirectory)
            let second = ChatController(cacheRoot: FileManager.default.temporaryDirectory)
            first.open(snapshot: snapshot())
            #expect(await waitUntil { await first.processIsActiveForTesting() })
            second.open(snapshot: snapshot(current: 9))
            #expect(await waitUntil { await second.processIsActiveForTesting() })
            #expect(await waitUntil { !(await first.processIsActiveForTesting()) })
            #expect(first.messages.isEmpty)
            await first.closeWindow()
            await second.closeWindow()
        }
    }

    @Test("limit reached: banner with the NN% and the reset time")
    func rateLimitBanner() async throws {
        await withClaudeMainActorTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "rate_limit",
        ]) {
            let controller = ChatController(cacheRoot: FileManager.default.temporaryDirectory)
            controller.open(snapshot: snapshot())
            controller.inputText = "Domanda"
            controller.submit(snapshot: snapshot())
            #expect(await waitUntil { controller.warningMessage != nil })
            #expect(controller.warningMessage?.contains("Usage limit reached") == true)
            #expect(controller.warningMessage?.contains("try again after") == true)
            await controller.closeWindow()
        }
    }

    @Test("low usage (\"allowed\" 27%/37%): no banner (regression test)")
    func lowUsageShowsNoBanner() async throws {
        await withClaudeMainActorTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let controller = ChatController(cacheRoot: FileManager.default.temporaryDirectory)
            controller.open(snapshot: snapshot())
            controller.inputText = "Domanda"
            controller.submit(snapshot: snapshot())
            #expect(await waitUntil { !controller.isResponding })
            #expect(controller.warningMessage == nil)
            await controller.closeWindow()
        }
    }

    @Test("high usage but still \"allowed\" (85%): gentle banner with the percentage")
    func highUsageShowsPercentBanner() async throws {
        await withClaudeMainActorTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "rate_limit_warning",
        ]) {
            let controller = ChatController(cacheRoot: FileManager.default.temporaryDirectory)
            controller.open(snapshot: snapshot())
            controller.inputText = "Domanda"
            controller.submit(snapshot: snapshot())
            #expect(await waitUntil { controller.warningMessage != nil })
            #expect(controller.warningMessage?.contains("85%") == true)
            #expect(controller.warningMessage?.contains("resets at") == true)
            await controller.closeWindow()
        }
    }

    @Test("CLI not signed in and CLI missing have readable errors")
    func cliErrors() async throws {
        await withClaudeMainActorTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "not_logged_in",
        ]) {
            let controller = ChatController(cacheRoot: FileManager.default.temporaryDirectory)
            controller.open(snapshot: snapshot())
            #expect(await waitUntil { controller.errorMessage?.contains("not signed in") == true })
            await controller.closeWindow()
        }
        await withClaudeMainActorTestEnv([ClaudeCLILocator.envOverrideKey: "/tmp/lelepdf-cli-che-non-esiste"]) {
            let controller = ChatController(cacheRoot: FileManager.default.temporaryDirectory)
            controller.open(snapshot: snapshot())
            #expect(await waitUntil { controller.errorMessage?.contains("not found") == true })
            await controller.closeWindow()
        }
    }
}
