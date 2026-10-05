import CryptoKit
import Foundation
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// REAL calls to Claude to generate the contents of the Draghi and Merck
/// documents (SPEC M4 item 11): the milestone's exit criterion ("the
/// generated contents are correct, compared by eye against the PDF")
/// requires a real call, not the fake CLI. Enabled only with
/// `LELEPDF_REAL_CLAUDE=1` (`scripts/test-real.sh`, never by the normal
/// `scripts/test.sh` suite).
///
/// One real call per document (2 in total, well under the budget of 4
/// allowed here by SPEC §10.2): the raw response is saved as a replay
/// fixture in `~/Library/Caches/LelePdf/test-staging/fixtures-real/` (the
/// test host must not write into the repository on the Desktop;
/// `scripts/test-real.sh` then copies them into
/// `LelePdfTests/Fixtures/real/`, git-ignored), and the same response is
/// also validated with `TocGenerator.validate` and printed for comparison by
/// eye against the PDF.
@Suite("Generated contents — real calls")
struct RealClaudeTocTests {
    static let fixturesDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/test-staging/fixtures-real", isDirectory: true)

    /// Checked inside the test body rather than with a suite-level
    /// `.enabled(if:)` trait: easier to diagnose (it prints the observed
    /// value) if `TEST_RUNNER_LELEPDF_REAL_CLAUDE` fails to reach the test
    /// process for some `xcodebuild`-related reason.
    private static func realCallsEnabled() -> Bool {
        let value = ProcessInfo.processInfo.environment["LELEPDF_REAL_CLAUDE"]
        if value != "1" {
            print("RealClaudeTocTests: skipped (LELEPDF_REAL_CLAUDE=\(value ?? "nil"), not \"1\") — normal in the ordinary scripts/test.sh suite")
        }
        return value == "1"
    }

    @Test("Draghi: contents generated with the real CLI")
    func draghiRealToc() async throws {
        guard Self.realCallsEnabled() else { return }
        try await Self.generateAndRecord(url: TestPDFs.draghi, label: "draghi")
    }

    @Test("Merck: contents generated with the real CLI")
    func merckRealToc() async throws {
        guard Self.realCallsEnabled() else { return }
        try await Self.generateAndRecord(url: TestPDFs.merck, label: "merck")
    }

    // MARK: -

    @MainActor
    private static func loadCandidates(url: URL) async throws -> (title: String, pageCount: Int, candidates: [TocCandidate])? {
        guard TestPDFs.ensureAvailable(url) else {
            Issue.record("test PDF not available: \(url.path)")
            return nil
        }
        guard let document = PDFDocument(url: url) else {
            Issue.record("PDF cannot be opened: \(url.path)")
            return nil
        }
        let pipeline = await PipelineRealDocumentHelper.run(document)
        let candidates = pipeline.output.tocCandidates
        guard !candidates.isEmpty else {
            Issue.record("no contents candidates for \(url.lastPathComponent): the text pipeline found nothing")
            return nil
        }
        let metadataTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let title = DocumentTitle.resolve(metadataTitle: metadataTitle, fileName: url.lastPathComponent)
        return (title, document.pageCount, candidates)
    }

    private static func generateAndRecord(url: URL, label: String) async throws {
        guard let loaded = try await loadCandidates(url: url) else { return }

        // No CLI override: the real one is wanted (SPEC §5.11, fixed search
        // order, normally ~/.local/bin/claude).
        unsetenv(ClaudeCLILocator.envOverrideKey)
        await ClaudeCLILocator.shared.resetCache()
        guard case .success(let info) = await ClaudeCLILocator.shared.info(), info.isUsable else {
            Issue.record("real CLI not found or not usable: cannot run the real test for \(label)")
            return
        }

        guard let systemPrompt = ClaudeResources.promptText(named: "toc"),
              let schema = ClaudeResources.schemaText(named: "toc") else {
            Issue.record("Prompts/toc.md or Schemas/toc.schema.json missing from the bundle")
            return
        }
        let prompt = TocGenerator.buildPrompt(title: loaded.title, pageCount: loaded.pageCount, candidates: loaded.candidates)

        let arguments = [
            "-p", prompt,
            "--model", ClaudeModel.sonnet.rawValue,
            "--safe-mode", "--tools", "",
            "--strict-mcp-config", "--no-session-persistence",
            "--system-prompt", systemPrompt,
            "--json-schema", schema,
            "--output-format", "json",
        ]

        print("=== Real call: generated contents (\(label)), \(loaded.candidates.count) candidates, \(loaded.pageCount) pages ===")
        let start = Date()
        let result = await OneShotProcess.run(
            executable: info.path, arguments: arguments,
            environment: ClaudeEnvironment.baseEnvironment(cliPath: info.path),
            currentDirectory: ClaudeEnvironment.cacheDirectory(), timeout: 120
        )
        let elapsed = Date().timeIntervalSince(start)

        guard !result.timedOut, result.status == 0 else {
            Issue.record("real call failed for \(label): status \(result.status), timeout \(result.timedOut), stderr: \(result.tail())")
            return
        }

        try saveFixture(prompt: prompt, rawResponse: result.stdout, label: label)
        try validateAndPrint(rawResponse: result.stdout, pageCount: loaded.pageCount, label: label, elapsed: elapsed)
    }

    private static func saveFixture(prompt: String, rawResponse: String, label: String) throws {
        try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = fixturesDir.appendingPathComponent("\(digest).json")
        try rawResponse.write(to: path, atomically: true, encoding: .utf8)
        print("real fixture saved: \(path.path) (key: sha256 of the prompt, \(label))")
    }

    private static func validateAndPrint(rawResponse: String, pageCount: Int, label: String, elapsed: TimeInterval) throws {
        guard let data = rawResponse.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("real response is not valid JSON for \(label)")
            return
        }
        let isError = json["is_error"] as? Bool ?? false
        let resultText = json["result"] as? String ?? ""
        guard !isError else {
            Issue.record("the real CLI responded with an error for \(label): \(resultText)")
            return
        }
        guard let structured = json["structured_output"], !(structured is NSNull),
              let structuredData = try? JSONSerialization.data(withJSONObject: structured),
              let output = try? JSONDecoder().decode(GeneratedTocEntries.self, from: structuredData) else {
            Issue.record("structured_output missing or not conforming to the schema for \(label)")
            return
        }
        let usage = ClaudeUsage.parse(json["usage"] as? [String: Any])
        let durationMs = json["duration_ms"] as? Int ?? Int(elapsed * 1000)

        print("=== Generated contents (\(label)) — \(output.entries.count) entries, \(usage.inputTokens)+\(usage.cacheCreationInputTokens) in (cache), \(usage.outputTokens) out, \(durationMs) ms ===")
        for entry in output.entries.sorted(by: { $0.page < $1.page }) {
            print("  [\(entry.level)] p.\(entry.page) — \(entry.title)")
        }

        switch TocGenerator.validate(output.entries, pageCount: pageCount) {
        case .success(let validated):
            #expect(!validated.isEmpty, "generated contents empty for \(label): compare by eye whether this is plausible (PDF without recognizable headings) or a prompt problem")
        case .failure(let failure):
            Issue.record("generated contents invalid for \(label): \(failure.reason)")
        }
    }
}

/// Mirrors `toc.schema.json`: used here only to decode the raw response saved
/// as a fixture, without going through `BatchRunner` (which would consume a
/// second real call).
private struct GeneratedTocEntries: Decodable {
    let entries: [GeneratedTocEntry]
}
