import CryptoKit
import Foundation
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// REAL calls to Claude to measure the quality of a block's analysis
/// (SPEC §7.5 "Quality goals", §11 row M5). Enabled only with
/// `LELEPDF_REAL_CLAUDE=1` (`scripts/test-real.sh`), never by the normal
/// suite. Same scheme as `RealClaudeTocTests.swift`: one one-shot call per
/// block (not through `BatchRunner`, so the raw response can be saved as a
/// replay fixture), followed by the same production post-processing
/// (`AnalysisPostProcessor`).
///
/// 5 consecutive blocks of the Merck case (starting from the first content
/// block: `BlockSegmenter` blocks are already prose only, without
/// headings/Exhibits) + 3 of the Draghi report (a chapter start and the two
/// following blocks).
@Suite("Block analysis — real calls")
struct RealBlockAnalysisTests {
    static let fixturesDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/test-staging/fixtures-real", isDirectory: true)

    private static func realCallsEnabled() -> Bool {
        let value = ProcessInfo.processInfo.environment["LELEPDF_REAL_CLAUDE"]
        if value != "1" {
            print("RealBlockAnalysisTests: skipped (LELEPDF_REAL_CLAUDE=\(value ?? "nil"))")
        }
        return value == "1"
    }

    @Test("Merck: 5 consecutive blocks from the first content block")
    func merckFiveBlocks() async throws {
        guard Self.realCallsEnabled() else { return }
        guard let loaded = try await Self.load(url: TestPDFs.merck) else { return }
        let selected = Array(loaded.structure.blocks.prefix(5))
        try #require(selected.count == 5, "the Merck case has fewer than 5 blocks: has the test PDF changed?")
        let metrics = await Self.analyzeSequence(
            label: "merck", documentTitle: loaded.title, allBlocks: loaded.structure.blocks,
            selected: selected, exhibits: loaded.structure.exhibits,
            systemPrompt: loaded.systemPrompt, schema: loaded.schema, cliPath: loaded.cliPath
        )
        Self.printSummary(label: "Merck", metrics: metrics)
    }

    @Test("Draghi: a chapter start and the two following blocks")
    func draghiChapterStart() async throws {
        guard Self.realCallsEnabled() else { return }
        guard let loaded = try await Self.load(url: TestPDFs.draghi) else { return }
        guard let startIndex = Self.chapterStartBlockIndex(structure: loaded.structure) else {
            Issue.record("no chapter start found in the Draghi report (level 1 headings after p.5)")
            return
        }
        let end = min(startIndex + 3, loaded.structure.blocks.count)
        let selected = Array(loaded.structure.blocks[startIndex ..< end])
        try #require(selected.count == 3, "fewer than 3 blocks available from a chapter start of the Draghi report")
        let metrics = await Self.analyzeSequence(
            label: "draghi", documentTitle: loaded.title, allBlocks: loaded.structure.blocks,
            selected: selected, exhibits: loaded.structure.exhibits,
            systemPrompt: loaded.systemPrompt, schema: loaded.schema, cliPath: loaded.cliPath
        )
        Self.printSummary(label: "Draghi", metrics: metrics)
    }

    // MARK: - Loading the document + resources (once per test)

    private struct Loaded {
        let title: String
        let structure: DocumentStructure
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
        let structure = DocumentStructure(
            fingerprint: "", pageCount: document.pageCount, headings: pipeline.output.headings,
            tocCandidates: pipeline.output.tocCandidates, exhibits: pipeline.output.exhibits,
            blocks: pipeline.output.blocks, textlessPages: false, removedHeaderFooterLines: [:],
            paragraphs: pipeline.output.paragraphs
        )

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

        return Loaded(title: title, structure: structure, systemPrompt: systemPrompt, schema: schema, cliPath: info.path)
    }

    /// First level 1 heading after p.5 (skips the cover/printed contents),
    /// then the first block whose `pageStart` falls on that page or later
    /// ("a chapter start").
    private static func chapterStartBlockIndex(structure: DocumentStructure) -> Int? {
        guard let heading = structure.headings.first(where: { $0.level == 1 && $0.pageIndex > 5 }) else { return nil }
        return structure.blocks.firstIndex(where: { $0.pageStart >= heading.pageIndex })
    }

    // MARK: - Call sequence (glossary/summary accumulated as AnalysisQueue would)

    struct BlockMetrics {
        var blockId: String
        var page: Int
        var words: Int
        var rewriteWords: Int
        var proposedMarks: Int
        var matchedMarks: Int
        var types: Set<MarkType>
        var durationMs: Int
        var usage: ClaudeUsage
        var rewriteText: String
        var blockCleanText: String
    }

    private static func analyzeSequence(
        label: String, documentTitle: String, allBlocks: [TextBlock], selected: [TextBlock],
        exhibits: [ExhibitRef], systemPrompt: String, schema: String, cliPath: String
    ) async -> [BlockMetrics] {
        var localAnalysis = AnalysisRecord()
        let order = allBlocks.map(\.id)
        var results: [BlockMetrics] = []

        for block in selected {
            let glossary = GlossaryBuilder.build(analysis: localAnalysis, blockOrder: order)
            let prevSummary = AnalysisInputBuilder.previousBlockSummary(blocks: allBlocks, analysis: localAnalysis, blockId: block.id)
            let prompt = AnalysisInputBuilder.buildPrompt(
                documentTitle: documentTitle, sectionPath: block.sectionPath, previousBlockSummary: prevSummary,
                glossary: glossary, blockCleanText: block.cleanText, exhibits: exhibits
            )

            let arguments = [
                "-p", prompt, "--model", ClaudeModel.sonnet.rawValue,
                "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
                "--system-prompt", systemPrompt, "--json-schema", schema, "--output-format", "json",
            ]
            print("=== Real call: block analysis \(block.id) (\(label)), p.\(block.pageStart + 1), \(block.words) words ===")
            let start = Date()
            let result = await OneShotProcess.run(
                executable: cliPath, arguments: arguments,
                environment: ClaudeEnvironment.baseEnvironment(cliPath: cliPath),
                currentDirectory: ClaudeEnvironment.cacheDirectory(), timeout: 120
            )
            let elapsed = Date().timeIntervalSince(start)
            guard !result.timedOut, result.status == 0 else {
                print("!!! call failed for block \(block.id): status \(result.status) timeout \(result.timedOut) stderr \(result.tail())")
                continue
            }
            saveFixture(prompt: prompt, rawResponse: result.stdout, label: "\(label)-\(block.id)")

            guard let data = result.stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let structured = json["structured_output"], !(structured is NSNull),
                  let structuredData = try? JSONSerialization.data(withJSONObject: structured),
                  let response = try? JSONDecoder().decode(AnalysisResponseRaw.self, from: structuredData) else {
                print("!!! invalid or schema-nonconforming response for block \(block.id)")
                continue
            }
            let usage = ClaudeUsage.parse(json["usage"] as? [String: Any])
            let durationMs = json["duration_ms"] as? Int ?? Int(elapsed * 1000)

            let output = AnalysisPostProcessor.process(
                AnalysisPostProcessor.Input(response: response, block: block, existingTerms: localAnalysis.terms)
            )
            for (id, term) in output.newTerms { localAnalysis.terms[id] = term }
            localAnalysis.blocks[block.id] = BlockAnalysis(
                status: .analyzed, analyzedAt: Date(), model: "sonnet", title: output.title,
                rewrite: output.rewrite, rewriteEdited: false, claudeRewrite: output.rewrite,
                marks: output.marks, links: output.links
            )

            let rewriteWords = wordCount(items: output.rewrite)
            let types = Set(output.marks.map(\.type))
            let rewriteText = RewritePlainText.render(output.rewrite)
            results.append(BlockMetrics(
                blockId: block.id, page: block.pageStart + 1, words: block.words, rewriteWords: rewriteWords,
                proposedMarks: output.totalMarkCount, matchedMarks: output.marks.count, types: types,
                durationMs: durationMs, usage: usage, rewriteText: rewriteText, blockCleanText: block.cleanText
            ))

            let pct = block.words > 0 ? Int((Double(rewriteWords) / Double(block.words) * 100).rounded()) : 0
            print("  block words \(block.words) · rewrite \(rewriteWords) (\(pct)%) · marks \(output.marks.count)/\(output.totalMarkCount) · types \(types.map(\.rawValue).sorted().joined(separator: ",")) · \(durationMs) ms · tokens in \(usage.inputTokens)+\(usage.cacheCreationInputTokens) out \(usage.outputTokens)")
            print("  --- rewrite ---")
            print("  " + rewriteText.replacingOccurrences(of: "\n", with: "\n  "))
        }
        return results
    }

    private static func wordCount(items: [RewriteItem]) -> Int {
        func words(_ s: String?) -> Int { (s ?? "").split { $0.isWhitespace }.count }
        return items.reduce(0) { total, item in
            total + words(item.text)
                + (item.items ?? []).reduce(0) { $0 + words($1) }
                + (item.columns ?? []).reduce(0) { $0 + words($1) }
                + (item.rows ?? []).reduce(0) { $0 + $1.reduce(0) { $0 + words($1) } }
        }
    }

    private static func saveFixture(prompt: String, rawResponse: String, label: String) {
        try? FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = fixturesDir.appendingPathComponent("\(digest).json")
        try? rawResponse.write(to: path, atomically: true, encoding: .utf8)
        print("real fixture saved: \(path.path) (\(label))")
    }

    private static func printSummary(label: String, metrics: [BlockMetrics]) {
        guard !metrics.isEmpty else {
            print("=== \(label): no block analyzed successfully ===")
            return
        }
        let matchedTotal = metrics.reduce(0) { $0 + $1.matchedMarks }
        let proposedTotal = metrics.reduce(0) { $0 + $1.proposedMarks }
        let meanPct = metrics.map { $0.words > 0 ? Double($0.rewriteWords) / Double($0.words) : 0 }.reduce(0, +) / Double(metrics.count)
        let allTypes = metrics.reduce(into: Set<MarkType>()) { $0.formUnion($1.types) }
        print("=== \(label): \(metrics.count) blocks — matched marks \(matchedTotal)/\(proposedTotal), average rewrite \(Int((meanPct * 100).rounded()))%, types present \(allTypes.map(\.rawValue).sorted()) ===")
    }
}
