import CryptoKit
import Foundation
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// Support shared only by the real-call chat suite. All paths live in the
/// staging cache: never the Desktop, the repository or the user's data folder.
@MainActor
enum ChatRealTestSupport {
    struct Response {
        let text: String
        let usage: ClaudeUsage
        let events: [ChatEvent]
        let elapsed: TimeInterval
        let isError: Bool
    }

    static let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/test-staging/chat-real", isDirectory: true)
    static let fixturesDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/test-staging/fixtures-real", isDirectory: true)

    static func realCallsEnabled() -> Bool {
        let value = ProcessInfo.processInfo.environment["LELEPDF_REAL_CLAUDE"]
        if value != "1" {
            print("ChatRealTests: skipping (LELEPDF_REAL_CLAUDE=\(value ?? "nil"))")
        }
        return value == "1"
    }

    static func useRealCLI() async throws {
        unsetenv(ClaudeCLILocator.envOverrideKey)
        await ClaudeCLILocator.shared.resetCache()
        guard case .success(let info) = await ClaudeCLILocator.shared.info(), info.isUsable else {
            throw ChatRealFailure.cliUnavailable
        }
    }

    static func loadSnapshot(
        url: URL, currentPageIndex: Int, visiblePageRange: ClosedRange<Int>
    ) async throws -> ChatDocumentSnapshot {
        guard TestPDFs.ensureAvailable(url), let document = PDFDocument(url: url) else {
            throw ChatRealFailure.pdfUnavailable(url.path)
        }
        let pipeline = await PipelineRealDocumentHelper.run(document)
        let pageTexts = cleanPageTexts(
            blocks: pipeline.output.blocks, pageCount: document.pageCount,
            fallback: (0 ..< document.pageCount).map { document.page(at: $0)?.string ?? "" }
        )
        let title = DocumentTitle.resolve(
            metadataTitle: document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
            fileName: url.lastPathComponent
        )
        let toc = pipeline.output.headings.map {
            ChatTOCEntry(title: $0.text, level: $0.level, page: $0.pageIndex)
        }
        return ChatDocumentSnapshot(
            title: title,
            fingerprint: DocumentFingerprint.compute(for: document),
            pageTexts: pageTexts,
            toc: toc,
            glossary: [],
            analyzedSummaries: [],
            currentPageIndex: currentPageIndex,
            visiblePageRange: visiblePageRange
        )
    }

    static func ask(
        session: ChatSession,
        iterator: ChatEventCursor,
        question: String,
        visiblePageRange: ClosedRange<Int>
    ) async -> Response? {
        let prefix = visibleRangeLabel(visiblePageRange)
        let started = Date()
        await session.send(question, visiblePageRange: prefix)
        var events: [ChatEvent] = []
        var streamedText = ""
        while let event = await iterator.next() {
            events.append(event)
            switch event {
            case .textDelta(let text):
                streamedText += text
            case .result(let usage, let resultText, let isError):
                let text = streamedText.isEmpty ? resultText : streamedText
                return Response(
                    text: text, usage: usage, events: events,
                    elapsed: Date().timeIntervalSince(started), isError: isError
                )
            case .error(let error):
                Issue.record("error from the real chat: \(error.userMessage)")
            default:
                break
            }
        }
        Issue.record("real chat stream ended without a result event")
        return nil
    }

    static func citationPages(in text: String) -> [Int] {
        let parser = MarkerParser()
        return (parser.feed(text) + parser.finish()).compactMap {
            if case .citation(_, let page, _) = $0 { return page }
            return nil
        }
    }

    static func externalText(in text: String) -> String {
        let parser = MarkerParser()
        return (parser.feed(text) + parser.finish()).compactMap {
            if case .text(let value, external: true) = $0 { return value }
            return nil
        }.joined()
    }

    static func recordFixture(
        question: String, visiblePageRange: ClosedRange<Int>, response: Response, label: String
    ) {
        let fullQuestion = "[\(visibleRangeLabel(visiblePageRange))] \(question)"
        let payload: [String: Any] = [
            "type": "result", "subtype": response.isError ? "error" : "success",
            "is_error": response.isError, "result": response.text,
            "usage": [
                "input_tokens": response.usage.inputTokens,
                "cache_creation_input_tokens": response.usage.cacheCreationInputTokens,
                "cache_read_input_tokens": response.usage.cacheReadInputTokens,
                "output_tokens": response.usage.outputTokens,
            ],
        ]
        saveFixture(keyText: fullQuestion, payload: payload, label: label)
    }

    static func recordTextFixture(
        question: String, visiblePageRange: ClosedRange<Int>, text: String, label: String
    ) {
        let fullQuestion = "[\(visibleRangeLabel(visiblePageRange))] \(question)"
        saveFixture(
            keyText: fullQuestion,
            payload: ["type": "result", "subtype": "success", "is_error": false, "result": text],
            label: label
        )
    }

    static func summarizeReal(_ messages: [ChatMessage]) async -> String? {
        guard let systemPrompt = ClaudeResources.promptText(named: "chat-summary"),
              case .success(let info) = await ClaudeCLILocator.shared.info(), info.isUsable else { return nil }
        let transcript = ChatTranscript.render(messages)
        guard !transcript.isEmpty else { return nil }
        let result = await OneShotProcess.run(
            executable: info.path,
            arguments: [
                "-p", transcript, "--model", ClaudeModel.sonnet.rawValue,
                "--safe-mode", "--tools", "", "--strict-mcp-config",
                "--no-session-persistence", "--system-prompt", systemPrompt,
                "--output-format", "json",
            ],
            environment: ClaudeEnvironment.baseEnvironment(cliPath: info.path),
            currentDirectory: ClaudeEnvironment.cacheDirectory(), timeout: 120
        )
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["is_error"] as? Bool != true,
              let text = json["result"] as? String, !text.isEmpty else { return nil }
        saveFixture(keyText: transcript, payload: json, label: "budget-summary")
        return text
    }

    private static func saveFixture(keyText: String, payload: [String: Any], label: String) {
        let digest = SHA256.hash(data: Data(keyText.utf8))
            .map { String(format: "%02x", $0) }.joined()
        do {
            try FileManager.default.createDirectory(at: fixturesDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: fixturesDirectory.appendingPathComponent("\(digest).json"), options: .atomic)
        } catch {
            Issue.record("real fixture not saved (\(label)): \(error.localizedDescription)")
        }
    }

    static func waitUntil(
        timeout: TimeInterval = 180,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    private static func visibleRangeLabel(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound
            ? "Visible page: \(range.lowerBound + 1)"
            : "Visible pages: \(range.lowerBound + 1)-\(range.upperBound + 1)"
    }

    private static func cleanPageTexts(
        blocks: [TextBlock], pageCount: Int, fallback: [String]
    ) -> [String] {
        var fragments = [[String]](repeating: [], count: pageCount)
        for block in blocks {
            let characters = Array(block.cleanText)
            for span in block.spans where fragments.indices.contains(span.page) {
                let lower = min(max(0, span.cleanStart), characters.count)
                let upper = min(max(lower, span.cleanStart + span.cleanLength), characters.count)
                if lower < upper { fragments[span.page].append(String(characters[lower ..< upper])) }
            }
        }
        return fragments.enumerated().map { index, values in
            let clean = values.joined(separator: "\n\n")
            return clean.isEmpty && fallback.indices.contains(index) ? fallback[index] : clean
        }
    }
}

/// Cursor over the real chat's event stream: a reference type instead of
/// `inout AsyncStream<ChatEvent>.Iterator` between `ask` (nonisolated,
/// called from the `@MainActor` tests) and the tests themselves, because
/// Swift 6 rejects an iterator passed by mutable reference across different
/// isolation domains ("sending risks causing data races"): only one caller
/// at a time uses it, in sequence, in these tests, never concurrently.
final class ChatEventCursor: @unchecked Sendable {
    private var iterator: AsyncStream<ChatEvent>.Iterator

    init(_ stream: AsyncStream<ChatEvent>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> ChatEvent? {
        await iterator.next()
    }
}

enum ChatRealFailure: Error, CustomStringConvertible {
    case cliUnavailable
    case pdfUnavailable(String)

    var description: String {
        switch self {
        case .cliUnavailable: "Real CLI not found or not usable"
        case .pdfUnavailable(let path): "Test PDF not available: \(path)"
        }
    }
}
