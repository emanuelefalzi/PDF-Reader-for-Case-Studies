import Foundation

/// `sonnet` by default, `opus` as an option (SPEC §5.11).
enum ClaudeModel: String, Sendable {
    case sonnet, opus
}

/// Tokens used by a call (SPEC §7.5, §7.8.2: input, cache created, cache
/// read, output).
struct ClaudeUsage: Sendable, Equatable {
    var inputTokens: Int = 0
    var cacheCreationInputTokens: Int = 0
    var cacheReadInputTokens: Int = 0
    var outputTokens: Int = 0

    /// Reads `usage{input_tokens, cache_creation_input_tokens,
    /// cache_read_input_tokens, output_tokens}` (SPEC §4, §7.8.2), shared by
    /// `BatchRunner` and `ChatSession`.
    static func parse(_ json: [String: Any]?) -> ClaudeUsage {
        guard let json else { return ClaudeUsage() }
        return ClaudeUsage(
            inputTokens: json["input_tokens"] as? Int ?? 0,
            cacheCreationInputTokens: json["cache_creation_input_tokens"] as? Int ?? 0,
            cacheReadInputTokens: json["cache_read_input_tokens"] as? Int ?? 0,
            outputTokens: json["output_tokens"] as? Int ?? 0
        )
    }
}

/// Input of a one-shot call (SPEC §7.5): user prompt, model, system prompt
/// and schema, already loaded as text (prompts and schemas live in Resources,
/// not in code).
struct BatchRequest: Sendable {
    var prompt: String
    var model: ClaudeModel = .sonnet
    var systemPrompt: String
    var jsonSchema: String
    /// `nil` = do not pass `--effort` (SPEC §4: the default effort is the
    /// verified one; `--effort low` loses marks).
    var effort: String?
}

/// Full outcome of a successful, validated call: the decoded value plus the
/// measurements to record (SPEC §10.2, §7.8.2).
struct BatchOutcome<T: Sendable>: Sendable {
    var value: T
    var usage: ClaudeUsage
    var durationMs: Int
}

/// Tests only (`Result<BatchOutcome<T>, ClaudeError>` with `==`): the
/// conditional conformance changes nothing at runtime for non-test code,
/// which does not need it.
extension BatchOutcome: Equatable where T: Equatable {}

/// Raw outcome of a successful call (the process finished successfully),
/// before the caller's validation: `structuredOutputData` may be `nil` if the
/// CLI did not produce valid JSON (SPEC "one retry").
private struct RawBatchOutput: Sendable {
    var structuredOutputData: Data?
    var resultText: String
    var usage: ClaudeUsage
    var durationMs: Int
    var isError: Bool
}

/// Queue and single process for one-shot calls (analysis/contents, SPEC
/// §6.3: "at most 1 analysis ... active at the same time across the whole
/// app"), with schema validation left to the caller (through `decode`, so
/// `BatchRunner` knows nothing about the `Analysis`/`TocGenerator` types) and
/// a single automatic retry on an invalid response (SPEC §7.5).
actor BatchRunner {
    static let shared = BatchRunner()

    /// Limit for the one-shot process (SPEC §7.5: 120 s). Configurable only
    /// by tests (e.g. 2 s to verify the cutoff without slowing the suite);
    /// `shared` always uses the production value.
    private let timeout: TimeInterval

    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private var usageLimitUntil: Date?

    init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    /// SPEC §5.12: "while the limit is active, they immediately show the same
    /// message". Read by the UI for the banner (§5.12) without having to
    /// attempt a call.
    var activeUsageLimit: Date? { usageLimitUntil }

    /// True if another call is already occupying the single process (SPEC
    /// §6.3 "Waiting: another window is analyzing").
    var isBusy: Bool { busy }

    /// Runs a one-shot call, in a FIFO queue behind any others (SPEC §6.3),
    /// failing fast if a usage limit is active (SPEC §5.12) unless
    /// `forceRetry` is set (§5.12 "Retry ... forces a new attempt anyway").
    /// `decode` validates and converts `structured_output`: if it fails
    /// (invalid JSON or schema not respected) there is exactly one retry
    /// (SPEC §7.5), then `.invalidResponse`.
    func run<T: Sendable>(
        _ request: BatchRequest,
        forceRetry: Bool = false,
        onWaiting: (@Sendable () -> Void)? = nil,
        decode: @escaping @Sendable (Data) -> T?
    ) async -> Result<BatchOutcome<T>, ClaudeError> {
        if !forceRetry, let usageLimitUntil, Date() < usageLimitUntil {
            return .failure(.usageLimit(resetsAt: usageLimitUntil))
        }
        let waiterId = UUID()
        let cancelToken = ProcessCancelToken()
        return await withTaskCancellationHandler {
            if busy { onWaiting?() }
            guard await acquireSlot(id: waiterId) else { return .failure(.cancelled) }
            defer { releaseSlot() }

            if cancelToken.isCancelled { return .failure(.cancelled) }

            if let outcome = await callAndValidate(request, cancelToken: cancelToken, decode: decode) {
                return outcome
            }
            if cancelToken.isCancelled { return .failure(.cancelled) }
            // Invalid response: a single retry (SPEC §7.5).
            if let outcome = await callAndValidate(request, cancelToken: cancelToken, decode: decode) {
                return outcome
            }
            return .failure(.invalidResponse)
        } onCancel: {
            cancelToken.cancel()
            Task { await self.cancelWaiter(id: waiterId) }
        }
    }

    /// One call + validation. `nil` specifically means "the process succeeded
    /// but `structured_output` is missing or fails `decode`": the only case
    /// the caller (`run`) retries. Every other outcome (a valid success, or an
    /// error) is final.
    private func callAndValidate<T: Sendable>(
        _ request: BatchRequest, cancelToken: ProcessCancelToken, decode: @Sendable (Data) -> T?
    ) async -> Result<BatchOutcome<T>, ClaudeError>? {
        switch await performCall(request, cancelToken: cancelToken) {
        case .failure(let error):
            recordUsageLimitIfNeeded(error)
            return .failure(error)
        case .success(let raw):
            if raw.isError {
                let error = ClaudeErrorMapper.usageLimit(in: raw.resultText)
                    ?? .processFailed(stderrTail: String(raw.resultText.suffix(400)))
                recordUsageLimitIfNeeded(error)
                return .failure(error)
            }
            guard let data = raw.structuredOutputData, let decoded = decode(data) else {
                return nil
            }
            return .success(BatchOutcome(value: decoded, usage: raw.usage, durationMs: raw.durationMs))
        }
    }

    /// Used only by tests: forces the limit active/inactive without going
    /// through a real call.
    func setUsageLimitForTesting(until date: Date?) {
        usageLimitUntil = date
    }

    private func recordUsageLimitIfNeeded(_ error: ClaudeError) {
        if case .usageLimit(let resetsAt) = error {
            usageLimitUntil = resetsAt ?? Date().addingTimeInterval(3600)
        }
    }

    // MARK: - FIFO queue (SPEC §6.3)

    /// `true` = slot obtained; `false` = cancelled while queued (SPEC §6.3
    /// "cancel while waiting"), removed by `cancelWaiter` before reaching the
    /// head of the queue.
    private func acquireSlot(id: UUID) async -> Bool {
        if !busy {
            busy = true
            return true
        }
        return await withCheckedContinuation { continuation in
            waiters.append((id, continuation))
        }
    }

    /// Hands the slot directly to the next in the queue, if any: `busy` stays
    /// true with no window in which a concurrent `run` could sneak in.
    private func releaseSlot() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        let next = waiters.removeFirst()
        next.continuation.resume(returning: true)
    }

    /// Called from `run`'s `onCancel` handler (outside the actor's isolation):
    /// if the caller was still queued, removes it and unblocks it immediately
    /// with `.cancelled`, instead of making it wait for its turn.
    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    // MARK: - The actual call (SPEC §7.5)

    private func performCall(_ request: BatchRequest, cancelToken: ProcessCancelToken) async -> Result<RawBatchOutput, ClaudeError> {
        guard case .success(let info) = await ClaudeCLILocator.shared.info() else { return .failure(.cliNotFound) }
        guard info.isUsable else { return .failure(.cliNotFound) }

        var arguments = [
            "-p", request.prompt,
            "--model", request.model.rawValue,
            "--safe-mode", "--tools", "",
            "--strict-mcp-config", "--no-session-persistence",
            "--system-prompt", request.systemPrompt,
            "--json-schema", request.jsonSchema,
            "--output-format", "json",
        ]
        if let effort = request.effort { arguments.append(contentsOf: ["--effort", effort]) }

        let result = await OneShotProcess.run(
            executable: info.path, arguments: arguments,
            environment: ClaudeEnvironment.baseEnvironment(cliPath: info.path),
            currentDirectory: ClaudeEnvironment.cacheDirectory(), timeout: timeout,
            cancelToken: cancelToken
        )
        if cancelToken.isCancelled { return .failure(.cancelled) }

        if result.timedOut { return .failure(.timeout) }
        if result.status != 0 { return .failure(ClaudeErrorMapper.map(result: result)) }

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Non-JSON body (SPEC "invalid response"): treated as a
            // "successful" outcome but without structured_output, so that
            // `run`'s retry mechanism kicks in.
            return .success(RawBatchOutput(structuredOutputData: nil, resultText: result.stdout, usage: ClaudeUsage(), durationMs: 0, isError: false))
        }

        let isError = json["is_error"] as? Bool ?? false
        let resultText = json["result"] as? String ?? ""
        let durationMs = json["duration_ms"] as? Int ?? 0
        let usage = ClaudeUsage.parse(json["usage"] as? [String: Any])
        var structuredData: Data?
        if let structured = json["structured_output"], !(structured is NSNull) {
            structuredData = try? JSONSerialization.data(withJSONObject: structured)
        }

        return .success(RawBatchOutput(structuredOutputData: structuredData, resultText: resultText, usage: usage, durationMs: durationMs, isError: isError))
    }
}
