import Foundation
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// REAL calls to Claude with the NEW prompt/schema (the ones the app uses
/// today, read from the bundle, not embedded text as in
/// `RealFormatComparisonTests`; there is no "old" one to compare against
/// here), on 3 real sections (one per test PDF, SPEC §4), with a budget of 3
/// calls (within the cap of 6 set for this piece of work and the overall 80
/// of SPEC §10.2). Enabled only with `LELEPDF_REAL_CLAUDE=1`
/// (`scripts/test-real.sh stili`).
///
/// Automatic verification: every line has one of the nine allowed types
/// (seven originally, plus definition and example). The schema itself
/// already enforces this on Claude's side; this check runs on the DECODED
/// response, a second check on the app side. Note/formula/consequence/
/// subheading are used with MODERATION (generous thresholds, not "never").
/// The quality requirement "used only when the text justifies it" is left to
/// a human spot-check, since it cannot be automated reliably.
@Suite("Real calls with the new style prompt (point/sub-point/note/formula/consequence/subheading)")
struct RealF7StyleTests {
    private static func realCallsEnabled() -> Bool {
        let value = ProcessInfo.processInfo.environment["LELEPDF_REAL_CLAUDE"]
        if value != "1" {
            print("RealF7StyleTests: skipped (LELEPDF_REAL_CLAUDE=\(value ?? "nil"))")
        }
        return value == "1"
    }

    private struct Loaded {
        let title: String
        let blocks: [TextBlock]
        let exhibits: [ExhibitRef]
        let systemPrompt: String
        let schema: String
        let cliPath: String
    }

    @MainActor
    private static func load(url: URL) async throws -> Loaded? {
        guard TestPDFs.ensureAvailable(url) else {
            Issue.record("test PDF not available: \(url.path)")
            return nil
        }
        guard let document = PDFDocument(url: url) else {
            Issue.record("PDF cannot be opened: \(url.path)")
            return nil
        }
        let pipeline = await PipelineRealDocumentHelper.run(document)
        guard !pipeline.output.blocks.isEmpty else {
            Issue.record("no blocks for \(url.lastPathComponent)")
            return nil
        }
        let metadataTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let title = DocumentTitle.resolve(metadataTitle: metadataTitle, fileName: url.lastPathComponent)

        guard let systemPrompt = ClaudeResources.promptText(named: "analysis"),
              let schema = ClaudeResources.schemaText(named: "analysis") else {
            Issue.record("Resources/Prompts/analysis.md or Resources/Schemas/analysis.schema.json missing from the bundle")
            return nil
        }

        unsetenv(ClaudeCLILocator.envOverrideKey)
        await ClaudeCLILocator.shared.resetCache()
        guard case .success(let info) = await ClaudeCLILocator.shared.info(), info.isUsable else {
            Issue.record("real CLI not found or not usable")
            return nil
        }

        return Loaded(title: title, blocks: pipeline.output.blocks, exhibits: pipeline.output.exhibits, systemPrompt: systemPrompt, schema: schema, cliPath: info.path)
    }

    /// Same idea as `RealFormatComparisonTests.pickComparisonBlock`: real
    /// prose, 3-10 paragraphs, 150-700 words, not a block made only of
    /// notes/sources.
    private static func pickBlock(_ blocks: [TextBlock]) -> TextBlock? {
        let candidates = Array(blocks.prefix(80))
        func paragraphCount(_ b: TextBlock) -> Int {
            b.cleanText.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        }
        func avgWordsPerParagraph(_ b: TextBlock) -> Double {
            let p = paragraphCount(b)
            return p > 0 ? Double(b.words) / Double(p) : 0
        }
        let goodProse = candidates.filter {
            $0.words >= 150 && $0.words <= 700
                && paragraphCount($0) >= 3 && paragraphCount($0) <= 10
                && avgWordsPerParagraph($0) >= 20
        }
        if let best = goodProse.max(by: { $0.words < $1.words }) { return best }
        let inRange = candidates.filter { $0.words >= 120 && $0.words <= 750 }
        return inRange.max(by: { avgWordsPerParagraph($0) < avgWordsPerParagraph($1) })
    }

    private static func words(_ s: String?) -> Int { (s ?? "").split { $0.isWhitespace }.count }

    private static func runOneCall(label: String, url: URL) async -> AnalysisPostProcessor.Output? {
        guard let loaded = try? await load(url: url) else { return nil }
        guard let block = pickBlock(loaded.blocks) else {
            Issue.record("\(label): no suitable block")
            return nil
        }
        let glossary = GlossaryBuilder.build(analysis: AnalysisRecord(), blockOrder: [block.id])
        let prompt = AnalysisInputBuilder.buildPrompt(
            documentTitle: loaded.title, sectionPath: block.sectionPath, previousBlockSummary: nil,
            glossary: glossary, blockCleanText: block.cleanText, exhibits: loaded.exhibits
        )
        let arguments = [
            "-p", prompt, "--model", ClaudeModel.sonnet.rawValue,
            "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
            "--system-prompt", loaded.systemPrompt, "--json-schema", loaded.schema, "--output-format", "json",
        ]
        print("=== Real call, style prompt (\(label)): block \(block.id), p.\(block.pageStart + 1)-\(block.pageEnd + 1), \(block.words) words ===")
        // The source text next to the response, to judge by hand whether
        // `definition`/`example` are justified (console only, local).
        print("  --- source text (\(label)) ---")
        print("  " + block.cleanText.replacingOccurrences(of: "\n", with: "\n  "))
        let result = await OneShotProcess.run(
            executable: loaded.cliPath, arguments: arguments,
            environment: ClaudeEnvironment.baseEnvironment(cliPath: loaded.cliPath),
            currentDirectory: ClaudeEnvironment.cacheDirectory(), timeout: 120
        )
        guard !result.timedOut, result.status == 0 else {
            Issue.record("\(label): call failed, status \(result.status), timeout \(result.timedOut)")
            print("!!! stderr/tail (\(label)): \(result.tail())")
            return nil
        }
        saveFixture(prompt: prompt, rawResponse: result.stdout, label: label)

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let structured = json["structured_output"], !(structured is NSNull),
              let structuredData = try? JSONSerialization.data(withJSONObject: structured),
              let response = try? JSONDecoder().decode(AnalysisResponseRaw.self, from: structuredData) else {
            Issue.record("\(label): invalid response or not conforming to the style schema")
            return nil
        }

        let output = AnalysisPostProcessor.process(AnalysisPostProcessor.Input(response: response, block: block, existingTerms: [:]))
        return output
    }

    private static func saveFixture(prompt: String, rawResponse: String, label: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/test-staging/fixtures-real", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = String(("f7-" + label + prompt).hashValue, radix: 16)
        let path = dir.appendingPathComponent("f7-\(label)-\(digest).json")
        try? rawResponse.write(to: path, atomically: true, encoding: .utf8)
        print("real style fixture saved: \(path.path) (\(label))")
    }

    /// Human-readable report printed to the console, plus the automatic checks
    /// on the FORMAT (SPEC quality §3 + "allowed types").
    private static func checkAndReport(label: String, output: AnalysisPostProcessor.Output) {
        #expect(output.rewrite.count == 1, "\(label): expected a single rewrite item (kind=outline)")
        guard let item = output.rewrite.first else { return }
        #expect(item.kind == .outline, "\(label): expected kind .outline, found \(item.kind)")
        let lines = item.lines ?? []
        #expect(!lines.isEmpty, "\(label): no lines produced")

        var counts: [RewriteLineType: Int] = [:]
        for line in lines { counts[line.type, default: 0] += 1 }
        for line in lines {
            if case .other = line.type {
                Issue.record("\(label): disallowed line type found: \(line.type.rawValue)")
            }
        }

        let mainCount = (counts[.point] ?? 0) + (counts[.consequence] ?? 0)
        #expect(mainCount >= 2, "\(label): too few level 0 points/consequences (\(mainCount)) — possible loss of content")

        // "Used only when the text justifies it": a generous anti-abuse
        // threshold, not an absolute zero. Notes/formulas rare relative to
        // the number of points, at most one subheading.
        let noteAndFormula = (counts[.note] ?? 0) + (counts[.formula] ?? 0)
        #expect(noteAndFormula <= max(2, mainCount / 2), "\(label): too many notes/formulas (\(noteAndFormula)) relative to the points (\(mainCount)) — possible unjustified use")
        #expect((counts[.subheading] ?? 0) <= 1, "\(label): more than one subheading in a single block — it should stay rare")
        // Definition and example: same generous anti-abuse threshold; the
        // "justified by the text" judgment is left to a spot-check by hand.
        let definitionAndExample = (counts[.definition] ?? 0) + (counts[.example] ?? 0)
        #expect(definitionAndExample <= max(2, mainCount / 2), "\(label): too many definitions/examples (\(definitionAndExample)) relative to the points (\(mainCount))")

        let rendered = RewritePlainText.render(output.rewrite)
        print("  title: \(output.title)")
        print("  total lines \(lines.count) · point/consequence \(mainCount) · sub-point \(counts[.subpoint] ?? 0) · explanation \(counts[.explanation] ?? 0) · note \(counts[.note] ?? 0) · formula \(counts[.formula] ?? 0) · subheading \(counts[.subheading] ?? 0) · definition \(counts[.definition] ?? 0) · example \(counts[.example] ?? 0)")
        print("  --- rewrite (\(label)) ---")
        print("  " + rendered.replacingOccurrences(of: "\n", with: "\n  "))
    }

    @Test("Merck: the new prompt produces only the allowed line types")
    func merck() async throws {
        guard Self.realCallsEnabled() else { return }
        guard let output = await Self.runOneCall(label: "merck", url: TestPDFs.merck) else {
            Issue.record("merck: style call failed")
            return
        }
        Self.checkAndReport(label: "merck", output: output)
    }

    @Test("Draghi: the new prompt produces only the allowed line types")
    func draghi() async throws {
        guard Self.realCallsEnabled() else { return }
        guard let output = await Self.runOneCall(label: "draghi", url: TestPDFs.draghi) else {
            Issue.record("draghi: style call failed")
            return
        }
        Self.checkAndReport(label: "draghi", output: output)
    }

    @Test("Wii: the new prompt produces only the allowed line types")
    func wii() async throws {
        guard Self.realCallsEnabled() else { return }
        guard let output = await Self.runOneCall(label: "wii", url: TestPDFs.wii) else {
            Issue.record("wii: style call failed")
            return
        }
        Self.checkAndReport(label: "wii", output: output)
    }
}
