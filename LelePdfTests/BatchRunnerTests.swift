import Foundation
import Testing
@testable import LelePdf

/// `BatchRunner` (SPEC §6.3, §7.5, M4 item 4): single app-wide queue,
/// validation + retry, error mapping, timeout, cancellation, usage limit.
/// Each test creates its own `BatchRunner()` (synthesized init, accessible
/// from `@testable import`) so it does not share state (queue, active
/// limit) with the other tests; `ClaudeCLILocator.shared` stays shared
/// instead, so the process environment is serialized with
/// `withClaudeTestEnv`.
@Suite("BatchRunner", .timeLimit(.minutes(1)))
struct BatchRunnerTests {
    /// Mirrors only the fields used by the tests in `default_analysis_output`
    /// of the fake CLI (`scripts/fake-claude/claude`): `JSONDecoder` ignores
    /// undeclared keys (`rewrite`, `links`), so there is no need to replicate
    /// the whole envelope.
    private struct AnalysisMarksOnly: Sendable, Decodable, Equatable {
        struct Mark: Sendable, Decodable, Equatable { let id: String; let text: String; let mark: String; let term: String }
        let title: String
        let marks: [Mark]
    }

    private func decodeMarks(_ data: Data) -> AnalysisMarksOnly? {
        try? JSONDecoder().decode(AnalysisMarksOnly.self, from: data)
    }

    private func sampleRequest(prompt: String = "Il testo parla di Merck e della FDA che approva il farmaco.") -> BatchRequest {
        BatchRequest(prompt: prompt, systemPrompt: "sistema di prova", jsonSchema: "{}")
    }

    @Test("success: decoded value and usage read correctly")
    func successReturnsDecodedValueAndUsage() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let runner = BatchRunner(timeout: 10)
            let outcome = await runner.run(sampleRequest(), decode: decodeMarks(_:))
            let value = try #require(try? outcome.get())
            #expect(value.value.marks.count == 8)
            #expect(value.usage.inputTokens == 120)
            #expect(value.usage.cacheCreationInputTokens == 3400)
            #expect(value.usage.cacheReadInputTokens == 0)
            #expect(value.usage.outputTokens == 640)
            #expect(value.durationMs == 1200)
        }
    }

    @Test("invalid JSON then success: a single automatic retry")
    func invalidJsonThenSuccessRetries() async throws {
        let modeFile = makeTempFilePath("mode-invalid-then-success")
        try "invalid_json\nsuccess\n".write(toFile: modeFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: modeFile) }
        let logPath = makeTempFilePath("log-invalid-then-success.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }

        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE_FILE": modeFile,
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let runner = BatchRunner(timeout: 10)
            let outcome = await runner.run(sampleRequest(), decode: decodeMarks(_:))
            let value = try #require(try? outcome.get())
            #expect(value.value.marks.count == 8)
            #expect(fakeClaudeBusyInvocationCount(logPath) == 2)
        }
    }

    @Test("invalid JSON twice: invalidResponse after a single retry")
    func invalidTwiceReturnsInvalidResponse() async throws {
        let logPath = makeTempFilePath("log-invalid-twice.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }

        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "invalid_json",
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let runner = BatchRunner(timeout: 10)
            let outcome = await runner.run(sampleRequest(), decode: decodeMarks(_:))
            #expect(outcome == .failure(.invalidResponse))
            #expect(fakeClaudeBusyInvocationCount(logPath) == 2)
        }
    }

    @Test("timeout: the process is killed and the error is .timeout")
    func timeoutKillsProcessAndReturnsTimeout() async throws {
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "timeout",
        ]) {
            let runner = BatchRunner(timeout: 2)
            let start = Date()
            let outcome = await runner.run(sampleRequest(), decode: decodeMarks(_:))
            let elapsed = Date().timeIntervalSince(start)
            #expect(outcome == .failure(.timeout))
            #expect(elapsed < 6, "expected terminate+SIGKILL within a few seconds, not the 30 s of the fake sleep")
        }
    }

    @Test("cancellation while running: .cancelled, does not wait for the timeout")
    func cancelWhileRunningReturnsCancelled() async throws {
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "timeout",
        ]) {
            let runner = BatchRunner(timeout: 60)
            let task = Task { await runner.run(sampleRequest(), decode: decodeMarks(_:)) }
            try await Task.sleep(for: .milliseconds(400))
            let start = Date()
            task.cancel()
            let outcome = await task.value
            let elapsed = Date().timeIntervalSince(start)
            #expect(outcome == .failure(.cancelled))
            #expect(elapsed < 5)
        }
    }

    @Test("cancellation while queued: .cancelled without ever starting the process")
    func cancelWhileWaitingNeverStartsProcess() async throws {
        let logPath = makeTempFilePath("log-cancel-waiting.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }

        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "timeout",
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let runner = BatchRunner(timeout: 60)
            let occupying = Task { await runner.run(sampleRequest(prompt: "occupa"), decode: decodeMarks(_:)) }
            try await Task.sleep(for: .milliseconds(300))
            #expect(await runner.isBusy)

            let waiting = Task { await runner.run(sampleRequest(prompt: "in coda"), decode: decodeMarks(_:)) }
            try await Task.sleep(for: .milliseconds(150))
            waiting.cancel()
            let waitingResult = await waiting.value
            #expect(waitingResult == .failure(.cancelled))
            #expect(fakeClaudeBusyInvocationCount(logPath) == 1, "only the call that occupied the process must have started it")

            occupying.cancel()
            _ = await occupying.value
        }
    }

    @Test("not logged in: .notLoggedIn")
    func notLoggedInMapsToError() async throws {
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "not_logged_in",
        ]) {
            let runner = BatchRunner(timeout: 10)
            let outcome = await runner.run(sampleRequest(), decode: decodeMarks(_:))
            #expect(outcome == .failure(.notLoggedIn))
        }
    }

    @Test("no network: .network")
    func networkMapsToError() async throws {
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "network",
        ]) {
            let runner = BatchRunner(timeout: 10)
            let outcome = await runner.run(sampleRequest(), decode: decodeMarks(_:))
            #expect(outcome == .failure(.network))
        }
    }

    @Test("usage limit: reset date read, fast-fail while active, forcing bypasses it")
    func rateLimitFastFailsUntilForced() async throws {
        let logPath = makeTempFilePath("log-rate-limit.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }

        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "rate_limit",
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let runner = BatchRunner(timeout: 10)
            let first = await runner.run(sampleRequest(), decode: decodeMarks(_:))
            guard case .failure(.usageLimit(let resetsAt)) = first, let resetsAt else {
                Issue.record("expected .usageLimit with a reset date, found \(first)")
                return
            }
            // The fake CLI generates "now + 1 h" (as an epoch timestamp): a fixed
            // value hand-written in the test would fall in the past as soon as the
            // session reaches that date, exactly as happened to the fake CLI itself
            // (see the comment in rate_limit_message()).
            #expect(abs(resetsAt.timeIntervalSinceNow - 3600) < 30)
            let countAfterFirst = fakeClaudeBusyInvocationCount(logPath)
            #expect(countAfterFirst == 1)

            let activeLimit = await runner.activeUsageLimit
            #expect(activeLimit == resetsAt)

            // While the limit is active: fast-fail, no new invocation.
            let second = await runner.run(sampleRequest(), decode: decodeMarks(_:))
            #expect(second == .failure(.usageLimit(resetsAt: resetsAt)))
            #expect(fakeClaudeBusyInvocationCount(logPath) == countAfterFirst)

            // forceRetry bypasses the active limit and really calls the CLI.
            setenv("FAKE_CLAUDE_MODE", "success", 1)
            let third = await runner.run(sampleRequest(), forceRetry: true, decode: decodeMarks(_:))
            let value = try #require(try? third.get())
            #expect(value.value.marks.count == 8)
            #expect(fakeClaudeBusyInvocationCount(logPath) == countAfterFirst + 1)
        }
    }

    @Test("one process at a time: with 3 concurrent requests at most one runs")
    func onlyOneProcessRunsAtATimeWithThreeConcurrentRequests() async throws {
        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_MODE": "timeout",
        ]) {
            let runner = BatchRunner(timeout: 60)
            let waitCounter = WaitCounter()
            let onWaiting: @Sendable () -> Void = { Task { await waitCounter.increment() } }

            let tasks = (0..<3).map { index in
                Task { await runner.run(sampleRequest(prompt: "richiesta \(index)"), onWaiting: onWaiting, decode: decodeMarks(_:)) }
            }
            try await Task.sleep(for: .milliseconds(400))

            #expect(await runner.isBusy)
            // With a single slot, at least 2 of the 3 requests must have found
            // themselves "waiting" (the third, if not the second, for sure).
            #expect(await waitCounter.value >= 1)

            for task in tasks { task.cancel() }
            let results = await withTaskGroup(of: Result<BatchOutcome<AnalysisMarksOnly>, ClaudeError>.self) { group in
                for task in tasks { group.addTask { await task.value } }
                return await group.reduce(into: []) { $0.append($1) }
            }
            #expect(results.allSatisfy { $0 == .failure(.cancelled) })
            #expect(!(await runner.isBusy))
        }
    }

    @Test("the arguments passed to the CLI are exactly those of SPEC §7.5, cwd is the cache folder")
    func argvContainsExactFlagsAndCwdIsCacheDirectory() async throws {
        let logPath = makeTempFilePath("log-argv.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }

        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let runner = BatchRunner(timeout: 10)
            let request = BatchRequest(prompt: "prompt di prova", model: .opus, systemPrompt: "sistema", jsonSchema: "{}")
            let outcome = await runner.run(request, decode: decodeMarks(_:))
            _ = try #require(try? outcome.get())

            let entries = readFakeClaudeLog(logPath)
            let entry = try #require(entries.last)
            let argv = try #require(entry["argv"] as? [String])
            let expected = [
                "-p", request.prompt,
                "--model", "opus",
                "--safe-mode", "--tools", "",
                "--strict-mcp-config", "--no-session-persistence",
                "--system-prompt", request.systemPrompt,
                "--json-schema", request.jsonSchema,
                "--output-format", "json",
            ]
            #expect(argv == expected)
            let cwd = try #require(entry["cwd"] as? String)
            #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == ClaudeEnvironment.cacheDirectory().resolvingSymlinksInPath().path)
        }
    }
}

/// `actor` counter to collect the calls to `onWaiting` from several
/// concurrent `Task`s without unsynchronized shared data.
private actor WaitCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
