import Foundation
import os

private let chatLog = Logger(subsystem: "com.emanuele.LelePdf", category: "chat")

/// Events published by the persistent chat process (SPEC §7.8). The marker
/// parser (`Chat/MarkerParser.swift`) consumes `textDelta`.
enum ChatEvent: Sendable, Equatable {
    case systemInit(model: String, sessionId: String?)
    case textDelta(String)
    case assistantMessage(String)
    case result(usage: ClaudeUsage, text: String, isError: Bool)
    case rateLimit(RateLimitInfo)
    case toolUse(name: String, input: String?)
    case toolResult(isError: Bool, content: String)
    case processExited(code: Int32)
    case error(ClaudeError)
}

/// Process modes/arguments (SPEC §7.8, §7.8.1): normal mode passes
/// `--tools ""`; search mode (its safety is only verified in M9) uses
/// `Read,Grep,Glob` with `--allowedTools`/`--permission-mode dontAsk` and a
/// dedicated working directory (`~/Library/Caches/LelePdf/<fingerprint>/pagine/`).
enum ChatProcessMode: Sendable, Equatable {
    case normal
    case search(workingDirectory: URL, allowedTools: [String])
}

/// A single chat process for the whole app (SPEC §6.3 "opening the chat in
/// another window closes the previous process"): it registers the active
/// session and stops the previous one when a new one starts.
actor ChatProcessOwner {
    static let shared = ChatProcessOwner()
    private weak var current: ChatSession?

    func register(_ session: ChatSession) async {
        let previous = current
        current = session
        if let previous, previous !== session { await previous.stop() }
    }

    func unregister(_ session: ChatSession) {
        if current === session { current = nil }
    }
}

/// Persistent process `claude -p --input-format stream-json ...` (SPEC §7.8):
/// an `actor` to serialize `send`/`stop` and the processing of incoming lines
/// (which originate from an external queue, see `ChatProcessIO`).
actor ChatSession {
    private enum IOEvent: Sendable {
        case line(String)
        case exit(Int32)
    }

    private let io = ChatProcessIO()
    private var continuation: AsyncStream<ChatEvent>.Continuation?
    private var ioEventTask: Task<Void, Never>?
    private let idleTimeout: TimeInterval
    private var idleGeneration = 0
    private var started = false

    init(idleTimeout: TimeInterval = 600) {
        self.idleTimeout = idleTimeout
    }

    var isRunning: Bool { started && io.isRunning }

    /// Starts the process and returns the event stream. Stops the app's
    /// previous chat session, if there was one (SPEC §6.3). The stream
    /// finishes on its own if the CLI is not found or fails to start.
    func start(model: ClaudeModel, systemPrompt: String, mode: ChatProcessMode = .normal) async -> AsyncStream<ChatEvent> {
        await ChatProcessOwner.shared.register(self)
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        self.continuation = continuation

        guard case .success(let info) = await ClaudeCLILocator.shared.info() else {
            continuation.yield(.error(.cliNotFound))
            continuation.finish()
            return stream
        }

        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--model", model.rawValue, "--safe-mode",
        ]
        let workingDirectory: URL
        switch mode {
        case .normal:
            arguments += ["--tools", ""]
            workingDirectory = ClaudeEnvironment.cacheDirectory()
        case .search(let directory, let allowedTools):
            arguments += ["--tools", "Read,Grep,Glob"]
            arguments += ["--allowedTools"] + allowedTools
            arguments += ["--permission-mode", "dontAsk"]
            workingDirectory = directory
        }
        arguments += ["--strict-mcp-config", "--no-session-persistence", "--system-prompt", systemPrompt]

        let (ioEvents, ioContinuation) = AsyncStream<IOEvent>.makeStream()
        ioEventTask = Task { [weak self] in
            for await event in ioEvents {
                guard let self else { break }
                switch event {
                case .line(let line): await self.handleLine(line)
                case .exit(let code): await self.handleExit(code)
                }
            }
        }

        do {
            try io.start(
                executable: info.path, arguments: arguments,
                environment: ClaudeEnvironment.baseEnvironment(cliPath: info.path),
                currentDirectory: workingDirectory,
                onLine: { line in ioContinuation.yield(.line(line)) },
                onExit: { code in
                    ioContinuation.yield(.exit(code))
                    ioContinuation.finish()
                }
            )
        } catch {
            ioContinuation.finish()
            ioEventTask?.cancel()
            ioEventTask = nil
            continuation.yield(.error(.processFailed(stderrTail: "\(error)")))
            continuation.finish()
            return stream
        }
        started = true
        resetIdleTimer()
        return stream
    }

    /// Verified input line (SPEC §4): preceded by the visible page range when
    /// provided (SPEC §7.8 "Every message ...").
    func send(_ text: String, visiblePageRange: String? = nil) {
        guard started else { return }
        resetIdleTimer()
        let fullText = visiblePageRange.map { "[\($0)] \(text)" } ?? text
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": fullText]]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        io.writeLine(line)
    }

    /// Closes stdin and terminates the process (SIGTERM, then kill after 2 s
    /// if it stays alive); SPEC §7.8 "closed ... when the window closes". It
    /// does not blindly wait the 2 s: it returns as soon as the process is
    /// really dead (normally almost immediately with SIGTERM), the same
    /// principle as `OneShotProcess.runBlocking`.
    func stop() async {
        guard started else { return }
        started = false
        idleGeneration += 1
        io.closeStdin()
        io.terminate()
        let deadline = Date().addingTimeInterval(2)
        while io.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if io.isRunning { io.forceKill() }
        ioEventTask?.cancel()
        ioEventTask = nil
        continuation?.finish()
        continuation = nil
        await ChatProcessOwner.shared.unregister(self)
    }

    // MARK: - Incoming lines (SPEC §7.8)

    private func handleLine(_ line: String) {
        guard started, let continuation else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        resetIdleTimer()

        switch type {
        case "system":
            let model = json["model"] as? String ?? ""
            continuation.yield(.systemInit(model: model, sessionId: json["session_id"] as? String))
        case "stream_event":
            if let event = json["event"] as? [String: Any],
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                continuation.yield(.textDelta(text))
            } else if let event = json["event"] as? [String: Any],
                      event["type"] as? String == "content_block_start",
                      let block = event["content_block"] as? [String: Any],
                      block["type"] as? String == "tool_use" {
                continuation.yield(.toolUse(
                    name: block["name"] as? String ?? "",
                    input: Self.jsonString(block["input"])
                ))
            }
        case "assistant":
            if let text = Self.text(fromMessage: json["message"] as? [String: Any]) {
                continuation.yield(.assistantMessage(text))
            }
            Self.emitToolUses(from: json["message"] as? [String: Any], continuation: continuation)
        case "user":
            Self.emitToolResults(from: json["message"] as? [String: Any], continuation: continuation)
        case "rate_limit_event":
            let info = RateLimitInfo.parse(json)
            if info.status != "allowed" {
                chatLog.notice("raw rate_limit_event: \(trimmed, privacy: .public)")
            } else {
                chatLog.debug("raw rate_limit_event: \(trimmed, privacy: .public)")
            }
            continuation.yield(.rateLimit(info))
        case "result":
            let usage = ClaudeUsage.parse(json["usage"] as? [String: Any])
            let text = json["result"] as? String ?? ""
            let isError = json["is_error"] as? Bool ?? false
            continuation.yield(.result(usage: usage, text: text, isError: isError))
        default:
            chatLog.debug("unknown chat event: \(type, privacy: .public)")
        }
    }

    private func handleExit(_ code: Int32) {
        // `stop()` sets `started` to false before sending SIGTERM. That
        // termination is intentional and must not also become a visible error
        // (nor leave two stray events in the stream). If instead the process
        // exits on its own, `started` is still true and the non-zero status
        // is mapped as usual.
        let exitedUnexpectedly = started
        if code != 0, exitedUnexpectedly {
            let stderr = io.errorTail()
            let result = ProcessRunResult(status: code, stdout: "", stderr: stderr, timedOut: false)
            continuation?.yield(.error(ClaudeErrorMapper.map(result: result)))
        }
        continuation?.yield(.processExited(code: code))
        continuation?.finish()
        continuation = nil
        started = false
        ioEventTask = nil
        Task { await ChatProcessOwner.shared.unregister(self) }
    }

    private static func text(fromMessage message: [String: Any]?) -> String? {
        guard let content = message?["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    private static func emitToolUses(
        from message: [String: Any]?, continuation: AsyncStream<ChatEvent>.Continuation
    ) {
        guard let content = message?["content"] as? [[String: Any]] else { return }
        for item in content where item["type"] as? String == "tool_use" {
            continuation.yield(.toolUse(
                name: item["name"] as? String ?? "",
                input: jsonString(item["input"])
            ))
        }
    }

    private static func emitToolResults(
        from message: [String: Any]?, continuation: AsyncStream<ChatEvent>.Continuation
    ) {
        guard let content = message?["content"] as? [[String: Any]] else { return }
        for item in content where item["type"] as? String == "tool_result" {
            let value = item["content"]
            let text: String
            if let value = value as? String { text = value } else { text = jsonString(value) ?? "" }
            continuation.yield(.toolResult(isError: item["is_error"] as? Bool ?? false, content: text))
        }
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let value = value as? String { return value }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Idle timeout (SPEC §7.8: "10 minutes")

    private func resetIdleTimer() {
        idleGeneration += 1
        let generation = idleGeneration
        Task { [weak self, idleTimeout] in
            try? await Task.sleep(for: .seconds(idleTimeout))
            await self?.idleTimedOut(generation: generation)
        }
    }

    private func idleTimedOut(generation: Int) async {
        guard generation == idleGeneration, started else { return }
        await stop()
    }
}
