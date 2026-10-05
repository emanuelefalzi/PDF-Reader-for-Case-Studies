import CryptoKit
import Foundation
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// REAL calls to Claude to verify the prompt's density per granularity: a
/// block at `.chapter` granularity (the whole chapter) must produce a MORE
/// CONDENSED outline (fewer first-level points relative to the number of
/// paragraphs) than a mechanical "one point per paragraph" would, while a
/// block at `.paragraph` granularity (a single paragraph of the SAME chapter)
/// stays on the current rule (one point per paragraph, unchanged). Enabled
/// only with `LELEPDF_REAL_CLAUDE=1` (`scripts/test-real.sh grana`), never by
/// the normal suite. Same scheme as `RealBlockAnalysisTests.swift`: one
/// one-shot call per block (not through `BatchRunner`), followed by the same
/// production post-processing.
///
/// 2 PDFs (Merck, Draghi) × 2 granularities (chapter, paragraph) = 4 calls,
/// exactly the cap allowed for this check.
@Suite("Chapter vs Paragraph density — real calls")
struct RealGranularityDensityTests {
    static let fixturesDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/test-staging/fixtures-real", isDirectory: true)

    private static func realCallsEnabled() -> Bool {
        let value = ProcessInfo.processInfo.environment["LELEPDF_REAL_CLAUDE"]
        if value != "1" {
            print("RealGranularityDensityTests: skipped (LELEPDF_REAL_CLAUDE=\(value ?? "nil"))")
        }
        return value == "1"
    }

    @Test("Merck: a whole chapter (chapter) vs a single paragraph of the same chapter (paragraph)")
    func merckChapterVsParagraph() async throws {
        guard Self.realCallsEnabled() else { return }
        try await Self.compareGranularities(label: "merck", url: TestPDFs.merck)
    }

    @Test("Draghi: a whole chapter (chapter) vs a single paragraph of the same chapter (paragraph)")
    func draghiChapterVsParagraph() async throws {
        guard Self.realCallsEnabled() else { return }
        try await Self.compareGranularities(label: "draghi", url: TestPDFs.draghi)
    }

    // MARK: - Loading (same scheme as RealBlockAnalysisTests.load)

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

    // MARK: - Comparison

    struct DensityMetrics {
        var granularity: SummaryGranularity
        var blockWords: Int
        var paragraphCount: Int
        var topLevelLineCount: Int // point + consequence, depth 0
        var subpointCount: Int
        var rewriteWords: Int
        var durationMs: Int
        var rewriteText: String
        var densityLineSent: Bool
    }

    @MainActor
    private static func compareGranularities(label: String, url: URL) async throws {
        guard let loaded = try await Self.load(url: url) else { return }

        // Contents candidates taken from the level 1 headings already found by
        // the pipeline (SPEC §7.3), the same ground-truth signal used
        // elsewhere for a "chapter start", without a Claude-generated contents
        // in this test (no contents call here, out of budget).
        let level1Entries = loaded.structure.headings.filter { $0.level == 1 }
            .map { TocEntry(id: "h-\($0.pageIndex)-\($0.lineIndex)", title: $0.text, level: 1, page: $0.pageIndex) }
        guard let chapterHeading = loaded.structure.headings.first(where: { $0.level == 1 && $0.pageIndex > 5 }) else {
            Issue.record("no chapter start found in \(url.lastPathComponent) (level 1 headings after p.5)")
            return
        }

        let chapterBlocks = BlockSegmenter.segment(paragraphs: loaded.structure.paragraphs, tocEntries: level1Entries, granularity: .chapter)
        guard let chapterBlock = chapterBlocks.first(where: { $0.pageStart >= chapterHeading.pageIndex }), chapterBlock.words >= 400 else {
            Issue.record("no sufficiently substantial 'chapter' block after p.\(chapterHeading.pageIndex + 1) in \(url.lastPathComponent)")
            return
        }
        // A document like the Merck case can have stretches of only
        // notes/citations (paragraphs of a few words). The low threshold is
        // deliberate (15, not 40) so a valid chapter is not discarded just
        // because the FIRST substantial paragraph is not huge; one readable
        // paragraph is enough for the "one point per paragraph" comparison at
        // the fine granularity.
        let paragraphBlocks = BlockSegmenter.segment(paragraphs: loaded.structure.paragraphs, tocEntries: level1Entries, granularity: .paragraph)
        guard let paragraphBlock = paragraphBlocks.first(where: {
            $0.pageStart >= chapterBlock.pageStart && $0.pageStart <= chapterBlock.pageEnd && $0.words >= 15
        }) else {
            Issue.record("no substantial 'paragraph' block inside the chosen chapter in \(url.lastPathComponent)")
            return
        }
        let paragraphCountInChapter = Self.countParagraphsCovering(chapterBlock, allParagraphBlocks: paragraphBlocks)

        print("=== \(label): chapter '\(chapterHeading.text)' -- chapter block \(chapterBlock.words) words (~\(paragraphCountInChapter) paragraphs), test paragraph block \(paragraphBlock.words) words ===")

        let chapterMetrics = await Self.analyzeOne(
            label: "\(label)-chapter", documentTitle: loaded.title, block: chapterBlock, granularity: .chapter,
            paragraphCount: paragraphCountInChapter, exhibits: loaded.structure.exhibits,
            systemPrompt: loaded.systemPrompt, schema: loaded.schema, cliPath: loaded.cliPath
        )
        let paragraphMetrics = await Self.analyzeOne(
            label: "\(label)-paragraph", documentTitle: loaded.title, block: paragraphBlock, granularity: .paragraph,
            paragraphCount: 1, exhibits: loaded.structure.exhibits,
            systemPrompt: loaded.systemPrompt, schema: loaded.schema, cliPath: loaded.cliPath
        )

        Self.printComparison(label: label, chapter: chapterMetrics, paragraph: paragraphMetrics)
    }

    /// How many `.paragraph` blocks (one per paragraph) fall within the page
    /// range of the `.chapter` block: a proxy for the number of real
    /// paragraphs in the chapter, to judge whether the outline was condensed.
    private static func countParagraphsCovering(_ chapterBlock: TextBlock, allParagraphBlocks: [TextBlock]) -> Int {
        allParagraphBlocks.filter { $0.pageStart >= chapterBlock.pageStart && $0.pageStart <= chapterBlock.pageEnd }.count
    }

    private static func analyzeOne(
        label: String, documentTitle: String, block: TextBlock, granularity: SummaryGranularity, paragraphCount: Int,
        exhibits: [ExhibitRef], systemPrompt: String, schema: String, cliPath: String
    ) async -> DensityMetrics? {
        let densityLine = AnalysisInputBuilder.densityLine(granularity: granularity, blockWords: block.words)
        let prompt = AnalysisInputBuilder.buildPrompt(
            documentTitle: documentTitle, sectionPath: block.sectionPath, previousBlockSummary: nil,
            glossary: [], blockCleanText: block.cleanText, exhibits: exhibits,
            granularity: granularity, blockWords: block.words
        )
        let arguments = [
            "-p", prompt, "--model", ClaudeModel.sonnet.rawValue,
            "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
            "--system-prompt", systemPrompt, "--json-schema", schema, "--output-format", "json",
        ]
        print("=== Real call: \(label), granularity \(granularity.rawValue), p.\(block.pageStart + 1), \(block.words) words, density line: \(densityLine != nil) ===")
        let start = Date()
        let result = await OneShotProcess.run(
            executable: cliPath, arguments: arguments,
            environment: ClaudeEnvironment.baseEnvironment(cliPath: cliPath),
            currentDirectory: ClaudeEnvironment.cacheDirectory(), timeout: 120
        )
        let elapsed = Date().timeIntervalSince(start)
        guard !result.timedOut, result.status == 0 else {
            print("!!! call failed for \(label): status \(result.status) timeout \(result.timedOut) stderr \(result.tail())")
            return nil
        }
        saveFixture(prompt: prompt, rawResponse: result.stdout, label: label)

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let structured = json["structured_output"], !(structured is NSNull),
              let structuredData = try? JSONSerialization.data(withJSONObject: structured),
              let response = try? JSONDecoder().decode(AnalysisResponseRaw.self, from: structuredData) else {
            print("!!! invalid or schema-nonconforming response for \(label)")
            return nil
        }
        let durationMs = json["duration_ms"] as? Int ?? Int(elapsed * 1000)
        let output = AnalysisPostProcessor.process(AnalysisPostProcessor.Input(response: response, block: block, existingTerms: [:]))

        let lines = RewriteOutlineReader.lines(for: output.rewrite)
        let topLevel = lines.filter { $0.type == .point || $0.type == .consequence }.count
        let subpoints = lines.filter { $0.type == .subpoint }.count
        let rewriteText = RewritePlainText.render(output.rewrite)
        let rewriteWords = rewriteText.split { $0.isWhitespace }.count

        return DensityMetrics(
            granularity: granularity, blockWords: block.words, paragraphCount: paragraphCount,
            topLevelLineCount: topLevel, subpointCount: subpoints, rewriteWords: rewriteWords,
            durationMs: durationMs, rewriteText: rewriteText, densityLineSent: densityLine != nil
        )
    }

    private static func saveFixture(prompt: String, rawResponse: String, label: String) {
        try? FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = fixturesDir.appendingPathComponent("\(digest).json")
        try? rawResponse.write(to: path, atomically: true, encoding: .utf8)
        print("real fixture saved: \(path.path) (\(label))")
    }

    private static func printComparison(label: String, chapter: DensityMetrics?, paragraph: DensityMetrics?) {
        print("=== \(label): density comparison ===")
        for metrics in [chapter, paragraph].compactMap({ $0 }) {
            let pct = metrics.blockWords > 0 ? Int((Double(metrics.rewriteWords) / Double(metrics.blockWords) * 100).rounded()) : 0
            print("  [\(metrics.granularity.rawValue)] \(metrics.blockWords) words (~\(metrics.paragraphCount) paragraphs) -> \(metrics.topLevelLineCount) first-level points, \(metrics.subpointCount) sub-points, rewrite \(metrics.rewriteWords) words (\(pct)%), density line sent: \(metrics.densityLineSent), \(metrics.durationMs) ms")
        }
        if let chapter, let paragraph, chapter.paragraphCount > 0 {
            let pointsPerParagraphChapter = Double(chapter.topLevelLineCount) / Double(chapter.paragraphCount)
            print("  first-level points per paragraph -- chapter: \(String(format: "%.2f", pointsPerParagraphChapter)) (expected << 1.0, never one point per paragraph over a whole chapter) · paragraph: \(paragraph.topLevelLineCount) over 1 paragraph (expected 1, the current rule)")
        }
    }
}
