import Foundation
import Observation

@MainActor
@Observable
final class ChatController {
    typealias SummaryProvider = @Sendable ([ChatMessage]) async -> String?

    var isPresented = false
    var scope: ChatScope = .chapter
    var inputText = ""
    private(set) var messages: [ChatMessage] = []
    private(set) var contextLabel = "Preparing context…"
    private(set) var scopeEstimates: [ChatScope: Int] = [:]
    private(set) var isPreparing = false
    private(set) var isResponding = false
    private(set) var warningMessage: String?
    private(set) var errorMessage: String?
    private(set) var contextUsedTokens = 0

    var budget: ChatBudget { ChatBudget(usedTokens: contextUsedTokens, limit: budgetLimit) }

    private let idleTimeout: TimeInterval
    private let cacheRoot: URL
    private let budgetLimit: Int
    private let summaryProvider: SummaryProvider
    private var session: ChatSession?
    private var eventTask: Task<Void, Never>?
    private var activeContextKey: String?
    private var memory: String?
    private var parser: MarkerParser?
    private var responseMessageID: UUID?
    private var processGeneration = UUID()
    private var startupTask: Task<Void, Never>?
    private var isWindowClosed = false

    init(
        idleTimeout: TimeInterval = 600,
        cacheRoot: URL? = nil,
        budgetLimit: Int? = nil,
        summaryProvider: SummaryProvider? = nil
    ) {
        self.idleTimeout = idleTimeout
        self.cacheRoot = cacheRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf", isDirectory: true)
        self.budgetLimit = budgetLimit ?? ChatPreferences.budget
        self.summaryProvider = summaryProvider ?? { messages in
            await ChatSummarizer.summarize(messages, model: ChatPreferences.model)
        }
    }

    func open(snapshot: ChatDocumentSnapshot) {
        isWindowClosed = false
        isPresented = true
        updateEstimates(snapshot)
        guard session == nil, !isPreparing else { return }
        startupTask = Task { [weak self] in
            await self?.prepareSession(snapshot: snapshot, addContextNote: false)
        }
    }

    func closePanel() {
        isPresented = false
    }

    func toggle(snapshot: ChatDocumentSnapshot) {
        if isPresented { closePanel() } else { open(snapshot: snapshot) }
    }

    func submit(snapshot: ChatDocumentSnapshot) {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        inputText = ""
        isResponding = true
        updateEstimates(snapshot)
        Task { await send(question, snapshot: snapshot) }
    }

    func summarizeAndContinue(snapshot: ChatDocumentSnapshot) {
        guard !isPreparing, !isResponding else { return }
        Task { await summarizeAndRestart(snapshot: snapshot, automatic: false) }
    }

    func newConversation(snapshot: ChatDocumentSnapshot) {
        Task {
            guard !isWindowClosed else { return }
            await stopProcess()
            startupTask = nil
            messages.removeAll()
            memory = nil
            contextUsedTokens = 0
            warningMessage = nil
            errorMessage = nil
            await prepareSession(snapshot: snapshot, addContextNote: false)
        }
    }

    func closeWindow() async {
        isWindowClosed = true
        isPresented = false
        startupTask?.cancel()
        startupTask = nil
        await stopProcess()
    }

    func processIsActiveForTesting() async -> Bool {
        guard let session else { return false }
        return await session.isRunning
    }

    func pageEstimate(_ scope: ChatScope) -> String {
        let tokens = scopeEstimates[scope] ?? 0
        if tokens >= 1_000 { return "\u{2248} \(max(1, tokens / 1_000))k tokens" }
        return "\u{2248} \(tokens) tokens"
    }

    // MARK: - Process and context

    private func send(_ question: String, snapshot: ChatDocumentSnapshot) async {
        if let startupTask {
            await startupTask.value
            self.startupTask = nil
        }
        if budget.shouldAutoSummarize, messages.contains(where: { $0.role == .assistant }) {
            await summarizeAndRestart(snapshot: snapshot, automatic: true)
        } else {
            await ensureCurrentContext(snapshot: snapshot)
        }
        guard let session else {
            isResponding = false
            return
        }
        errorMessage = nil
        isResponding = true
        messages.append(ChatMessage(role: .user, rawText: question))
        parser = MarkerParser()
        let answer = ChatMessage(role: .assistant, rawText: "")
        responseMessageID = answer.id
        messages.append(answer)
        await session.send(question, visiblePageRange: visibleRangeLabel(snapshot.visiblePageRange))
    }

    private func ensureCurrentContext(snapshot: ChatDocumentSnapshot) async {
        guard let plan = await makePlan(snapshot) else { return }
        if session == nil {
            await start(plan)
        } else if activeContextKey != plan.key {
            // First free the app's single chat-process slot; the one-shot
            // summary must not overlap the live session.
            await stopProcess()
            let summary = await makeSummary()
            if !summary.isEmpty { memory = summary }
            guard let updatedPlan = await makePlan(snapshot) else { return }
            messages.append(ChatMessage(role: .note, rawText: "Context changed: \(updatedPlan.label.replacingOccurrences(of: "Context: ", with: ""))"))
            await start(updatedPlan)
        }
    }

    private func prepareSession(snapshot: ChatDocumentSnapshot, addContextNote: Bool) async {
        guard session == nil, !isWindowClosed, !Task.isCancelled else { return }
        guard let plan = await makePlan(snapshot) else { return }
        guard !isWindowClosed, !Task.isCancelled else { return }
        if addContextNote { messages.append(ChatMessage(role: .note, rawText: "Context changed: \(plan.label)")) }
        await start(plan)
    }

    private func makePlan(_ snapshot: ChatDocumentSnapshot) async -> ChatContextPlan? {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let selectedScope = scope
            let currentMemory = memory
            let root = cacheRoot
            let plan = try await Task.detached {
                try ChatContextBuilder.build(
                    snapshot: snapshot, scope: selectedScope, memory: currentMemory, cacheRoot: root
                )
            }.value
            contextLabel = plan.label
            return plan
        } catch let error as ChatContextError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = String(localized: "Can't prepare the chat context.")
        }
        return nil
    }

    private func start(_ plan: ChatContextPlan) async {
        guard !isWindowClosed, !Task.isCancelled else { return }
        let newSession = ChatSession(idleTimeout: idleTimeout)
        session = newSession
        activeContextKey = plan.key
        let generation = UUID()
        processGeneration = generation
        let stream = await newSession.start(model: ChatPreferences.model, systemPrompt: plan.systemPrompt, mode: plan.mode)
        guard !isWindowClosed, !Task.isCancelled else {
            await newSession.stop()
            if session === newSession { session = nil }
            return
        }
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                self?.handle(event)
            }
            self?.streamEnded(generation: generation)
        }
    }

    private func stopProcess() async {
        processGeneration = UUID()
        eventTask?.cancel()
        eventTask = nil
        if let session { await session.stop() }
        session = nil
        activeContextKey = nil
        isResponding = false
        finishParser()
    }

    private func summarizeAndRestart(snapshot: ChatDocumentSnapshot, automatic: Bool) async {
        isPreparing = true
        if automatic { messages.append(ChatMessage(role: .note, rawText: "Context almost full: summarizing automatically…")) }
        await stopProcess()
        let summary = await makeSummary()
        memory = summary
        messages.append(ChatMessage(role: .divider, rawText: "Conversation summarized"))
        contextUsedTokens = 0
        isPreparing = false
        await prepareSession(snapshot: snapshot, addContextNote: false)
    }

    private func makeSummary() async -> String {
        let visibleMessages = messages
        return await summaryProvider(visibleMessages) ?? ChatTranscript.fallbackSummary(visibleMessages)
    }

    // MARK: - Streaming events

    private func handle(_ event: ChatEvent) {
        switch event {
        case .textDelta(let delta):
            append(delta)
        case .assistantMessage:
            break // The deltas are the visible source; this avoids the final duplicate.
        case .result(let usage, let text, let isError):
            if let id = responseMessageID,
               let index = messages.firstIndex(where: { $0.id == id }),
               messages[index].rawText.isEmpty,
               !text.isEmpty {
                append(text)
            }
            finishParser()
            // The result event reports the size of the whole current context:
            // input + cache created + cache read. Turns are not summed.
            contextUsedTokens = usage.inputTokens + usage.cacheCreationInputTokens + usage.cacheReadInputTokens
            isResponding = false
            if isError { errorMessage = text.isEmpty ? String(localized: "Claude did not complete the response.") : text }
        case .rateLimit(let info):
            switch ChatRateLimitBanner.action(for: info) {
            case .show(let text): warningMessage = text
            case .clear: warningMessage = nil
            case .ignore: break
            }
        case .error(let error):
            errorMessage = error.userMessage
            isResponding = false
        case .processExited(let code):
            if code != 0, errorMessage == nil { errorMessage = String(localized: "The Claude chat closed unexpectedly.") }
            isResponding = false
        case .systemInit:
            break
        case .toolUse, .toolResult:
            break
        }
    }

    private func append(_ delta: String) {
        guard let parser, let id = responseMessageID,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].rawText += delta
        appendEvents(parser.feed(delta), to: index)
    }

    private func finishParser() {
        guard let parser, let id = responseMessageID,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            self.parser = nil
            responseMessageID = nil
            return
        }
        appendEvents(parser.finish(), to: index)
        self.parser = nil
        responseMessageID = nil
    }

    private func appendEvents(_ events: [ChatMarkerEvent], to index: Int) {
        for event in events {
            switch event {
            case .text(let text, external: false): appendSegment(.text(text), to: index)
            case .text(let text, external: true): appendSegment(.external(text), to: index)
            case .citation(let label, let page, _): messages[index].segments.append(.citation(label: label, page: page))
            }
        }
    }

    private func appendSegment(_ segment: ChatSegment, to index: Int) {
        if let last = messages[index].segments.last {
            switch (last, segment) {
            case (.text(let old), .text(let new)):
                messages[index].segments[messages[index].segments.count - 1] = .text(old + new); return
            case (.external(let old), .external(let new)):
                messages[index].segments[messages[index].segments.count - 1] = .external(old + new); return
            default: break
            }
        }
        messages[index].segments.append(segment)
    }

    private func streamEnded(generation: UUID) {
        guard generation == processGeneration else { return }
        finishParser()
        session = nil
        activeContextKey = nil
        isResponding = false
    }

    private func updateEstimates(_ snapshot: ChatDocumentSnapshot) {
        scopeEstimates = ChatContextBuilder.estimates(for: snapshot)
    }

    private func visibleRangeLabel(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound
            ? "Visible page: \(range.lowerBound + 1)"
            : "Visible pages: \(range.lowerBound + 1)-\(range.upperBound + 1)"
    }
}
