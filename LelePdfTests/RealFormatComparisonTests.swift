import CryptoKit
import Foundation
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// REAL calls to Claude for the summary format work (real runs on 3 PDFs,
/// comparing the previous prompt with the new one, with a budget of at most
/// 12 calls). Enabled only with `LELEPDF_REAL_CLAUDE=1`
/// (`scripts/test-real.sh format`), same scheme as
/// `RealBlockAnalysisTests`/`RealClaudeTocTests`: one one-shot call per
/// block (not through `BatchRunner`), followed by the same production
/// post-processing (`AnalysisPostProcessor`).
///
/// Compares, on the SAME real block, the OLD prompt (embedded below, the
/// exact text of `Resources/Prompts/analysis.md` before this change) against
/// the NEW one (read from the bundle, the one the app really uses today),
/// against the quality criteria: percentage of content in bullet points, one
/// bullet for each original paragraph, order preserved, nothing invented
/// (the latter is verified by a human spot-check of the output printed below,
/// since it cannot be automated reliably: the "spot-check reading" method of
/// the quality criteria).
@Suite("Summary format: points/sub-points — real comparison calls")
struct RealFormatComparisonTests {
    private static func realCallsEnabled() -> Bool {
        let value = ProcessInfo.processInfo.environment["LELEPDF_REAL_CLAUDE"]
        if value != "1" {
            print("RealFormatComparisonTests: skipped (LELEPDF_REAL_CLAUDE=\(value ?? "nil"))")
        }
        return value == "1"
    }

    // MARK: - OLD prompt/schema (as before the summary format change):
    // literal text, not an external file. This avoids any Desktop access from
    // the test process (the known TCC privacy-prompt risk) and keeps the
    // comparison reproducible even if the bundle file changes again in the
    // future.
    private static let oldSystemPrompt = #"""
# Analysis of a PDF block (SPEC paragraph 7.5)

You help a university student study a PDF. You receive one block of the PDF
(a paragraph group or a subsection, in its original language) plus some
context, and return structured data matching the given JSON schema
(`analysis.schema.json`).

## Rewrite

1. Rewrite in the SAME language as the source block. Stay faithful: never add
   facts, numbers, names or conclusions that are not in the block. Never use
   outside knowledge to fill a gap.
2. The rewrite must be standalone and understandable on its own: resolve
   references such as "as discussed above", "the former", "see Exhibit 3" by
   stating what they refer to (using the document title, section path and the
   previous block's summary you are given), or drop the reference if it
   cannot be resolved.
3. The rewrite's total length (all items combined) must not exceed 60% of the
   word count of the source block. Prefer fewer, denser items over padding.
4. Item kinds, in the order that fits the content:
   - `summary`: 1-2 sentences, always the first item of the rewrite.
   - `definition`: a term being defined, in a labelled box.
   - `bullets`: a bullet list (`items`), ONE idea per bullet, at most ~20
     words each. To show a cause leading to an effect, start the bullet with
     "→ " (arrow and a space) exactly once; never add a second arrow.
   - `steps`: a numbered sequence or a timeline (`items`, one per step).
   - `table`: a small table (`columns`, `rows`); at most 4 columns and 8 rows
     -- if the source has more, keep only the most important rows/columns.
   - `callout`: a single important consequence or warning worth a visual
     highlight (`text`).
   - `paragraph`: ordinary prose that doesn't fit the kinds above (`text`).
   The student scans the rewrite quickly, so after the `summary` DEFAULT TO
   `bullets` (typically 3-6 bullets): split a paragraph of facts, reasons,
   actors or consequences into separate bullets instead of writing prose.
   Use `steps` for sequences/timelines and `table` for comparable figures.
   Use `paragraph` only for a short narrative passage that genuinely loses
   meaning when split, and never more than one `paragraph` per block.
5. Ignore running headers, page numbers, and copyright/licence lines if any
   slipped into the block text.
6. Exhibits, figures and tables are never analysed: if the block text cites
   one (shown to you as `[Exhibit 5, p. 19]`), you may mention the citation
   in the rewrite but must not describe or reconstruct its content.

## Marks

7. Marks point at key spans IN THE SOURCE BLOCK TEXT. The field `text` must
   be copied EXACTLY as it appears in the block (same spelling, same case,
   same punctuation) -- it will be searched for verbatim in the block. Prefer
   short spans of 1-5 words. Use at most 12 marks per block.
8. Give each mark a short id, unique within this response: `"m1"`, `"m2"`,
   and so on.
9. Mark types:
   - `rectangle`: a concept or a thing.
   - `circle`: an actor (a company, a person, an institution), a number or a
     date.
   - `underline`: an action or a decision.
   - `arrow`: a consequence or an effect.
   When the block text describes actions and their effects, use all four
   types rather than only `rectangle`/`circle` -- the map (paragraph 7.7)
   depends on having `underline`/`arrow` marks to build links from.
10. `term`: the canonical form of the concept behind the mark (used to group
    repeated mentions of the same thing, e.g. "the FDA" and "the Food and
    Drug Administration" both get `term: "FDA"`).
11. `termId`: you are given a glossary of terms already used earlier in this
    document (`termId`, term, mark type). If a mark refers to the SAME
    concept as a glossary entry, set `termId` to that entry's id exactly --
    do not invent a new one for a concept that is already in the glossary.
    Leave `termId` out for a genuinely new concept.
12. In the rewrite text (`text`/`items`/table cells), wrap a mention of a
    marked term with `{{mX|shown words}}`, where `mX` is the id of the mark
    from this same response and "shown words" is the exact text to display
    (it does not need to match the mark's source `text` character-for-
    character, since the rewrite is paraphrased -- but it must be the same
    concept). Only wrap mentions that correspond to a mark you produced.

## Links

13. A link connects two marked concepts, by mark id or by `termId` (use
    `termId` when linking to a concept that already existed in the
    glossary). `via` is optional: the id of the `underline` (action) or
    `arrow` (effect) mark that expresses the relationship, when there is
    one. `label`: a short label for the link, usually taken from the
    `underline`/`arrow` mark's text. `kind`: `action` for a decision/action
    link, `effect` for a consequence/effect link.
14. Only create a link when the source text actually connects the two
    concepts (e.g. "X decided Y", "Z caused W"); do not infer a link from
    mere co-occurrence in the same block.

## Title

15. `title`: a short title for this block (a few words), suitable as a card
    heading in the app's right panel.
"""#
    private static let oldSchema = #"""
{
  "type": "object",
  "properties": {
    "title": { "type": "string" },
    "rewrite": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "kind": { "type": "string", "enum": ["summary", "definition", "bullets", "steps", "table", "callout", "paragraph"] },
          "text": { "type": "string" },
          "items": { "type": "array", "items": { "type": "string" } },
          "columns": { "type": "array", "items": { "type": "string" } },
          "rows": { "type": "array", "items": { "type": "array", "items": { "type": "string" } } }
        },
        "required": ["kind"]
      }
    },
    "marks": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id": { "type": "string" },
          "text": { "type": "string" },
          "mark": { "type": "string", "enum": ["rectangle", "circle", "underline", "arrow"] },
          "term": { "type": "string" },
          "termId": { "type": "string" }
        },
        "required": ["id", "text", "mark", "term"]
      }
    },
    "links": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "from": { "type": "string" },
          "to": { "type": "string" },
          "via": { "type": "string" },
          "label": { "type": "string" },
          "kind": { "type": "string", "enum": ["action", "effect"] }
        },
        "required": ["from", "to", "label", "kind"]
      }
    }
  },
  "required": ["title", "rewrite", "marks", "links"]
}
"""#

    // MARK: - Loading the document + resources (once per test)

    private struct Loaded {
        let title: String
        let blocks: [TextBlock]
        let exhibits: [ExhibitRef]
        let newSystemPrompt: String
        let newSchema: String
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

        guard let newSystemPrompt = ClaudeResources.promptText(named: "analysis"),
              let newSchema = ClaudeResources.schemaText(named: "analysis") else {
            Issue.record("Resources/Prompts/analysis.md or Resources/Schemas/analysis.schema.json missing from the bundle")
            return nil
        }

        unsetenv(ClaudeCLILocator.envOverrideKey)
        await ClaudeCLILocator.shared.resetCache()
        guard case .success(let info) = await ClaudeCLILocator.shared.info(), info.isUsable else {
            Issue.record("real CLI not found or not usable")
            return nil
        }

        return Loaded(
            title: title, blocks: pipeline.output.blocks, exhibits: pipeline.output.exhibits,
            newSystemPrompt: newSystemPrompt, newSchema: newSchema, cliPath: info.path
        )
    }

    /// A block that is "good for comparison": REAL prose, not a block made
    /// only of sources/footnotes under a table (an observation from the first
    /// run: `ParagraphBuilder` counts even a single note/citation line as a
    /// "paragraph", so a "Sources and Notes for Exhibits" block came out with
    /// 66-89 "paragraphs" of 1-7 words each, which is not what the user means
    /// by "paragraph by paragraph"). A minimum average number of words per
    /// paragraph is therefore required, not just the raw paragraph count:
    /// `avgWordsPerParagraph` discards notes/sources sections and prefers
    /// continuous prose of 3 to 10 paragraphs, 150-700 words in total (a
    /// single readable call).
    private static func pickComparisonBlock(_ blocks: [TextBlock]) -> TextBlock? {
        let candidates = Array(blocks.prefix(80))
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
        // Fallback: no block meets all the thresholds together (for example
        // a document with progressively shorter/longer paragraphs). Pick the
        // one with the highest average words per paragraph within the length
        // range anyway, to avoid falling back on a block made only of notes.
        let inRange = candidates.filter { $0.words >= 120 && $0.words <= 750 }
        return inRange.max(by: { avgWordsPerParagraph($0) < avgWordsPerParagraph($1) })
    }

    private static func paragraphCount(_ block: TextBlock) -> Int {
        block.cleanText.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    // MARK: - One call (old or new prompt), same production post-processing

    struct CallMetrics {
        var label: String
        var paragraphCount: Int
        var mainBulletCount: Int
        var totalRewriteWords: Int
        var bulletsWords: Int
        var rewriteText: String
        var titles: [String]
    }

    private static func runOneCall(
        label: String, documentTitle: String, block: TextBlock, exhibits: [ExhibitRef],
        systemPrompt: String, schema: String, cliPath: String
    ) async -> CallMetrics? {
        let glossary = GlossaryBuilder.build(analysis: AnalysisRecord(), blockOrder: [block.id])
        let prompt = AnalysisInputBuilder.buildPrompt(
            documentTitle: documentTitle, sectionPath: block.sectionPath, previousBlockSummary: nil,
            glossary: glossary, blockCleanText: block.cleanText, exhibits: exhibits
        )
        let arguments = [
            "-p", prompt, "--model", ClaudeModel.sonnet.rawValue,
            "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
            "--system-prompt", systemPrompt, "--json-schema", schema, "--output-format", "json",
        ]
        print("=== Real call (\(label)): block \(block.id), p.\(block.pageStart + 1)-\(block.pageEnd + 1), \(block.words) words, \(paragraphCount(block)) paragraphs ===")
        let result = await OneShotProcess.run(
            executable: cliPath, arguments: arguments,
            environment: ClaudeEnvironment.baseEnvironment(cliPath: cliPath),
            currentDirectory: ClaudeEnvironment.cacheDirectory(), timeout: 120
        )
        guard !result.timedOut, result.status == 0 else {
            print("!!! call failed (\(label)): status \(result.status) timeout \(result.timedOut) stderr \(result.tail())")
            return nil
        }
        saveFixture(prompt: prompt, rawResponse: result.stdout, label: label)

        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let structured = json["structured_output"], !(structured is NSNull),
              let structuredData = try? JSONSerialization.data(withJSONObject: structured),
              let response = try? JSONDecoder().decode(AnalysisResponseRaw.self, from: structuredData) else {
            print("!!! invalid or schema-nonconforming response (\(label))")
            return nil
        }

        let output = AnalysisPostProcessor.process(
            AnalysisPostProcessor.Input(response: response, block: block, existingTerms: [:])
        )
        let bulletsItems = output.rewrite.filter { $0.kind == .bullets }
        let mainBulletCount = bulletsItems.reduce(0) { $0 + ($1.items?.count ?? 0) }
        let totalWords = wordCount(items: output.rewrite)
        let bulletsWords = bulletsItems.reduce(0) { total, item in
            total + words(item.text) + (item.items ?? []).reduce(0) { $0 + words($1) }
                + (item.subItems ?? []).reduce(0) { $0 + $1.reduce(0) { $0 + words($1) } }
        }
        let rewriteText = RewritePlainText.render(output.rewrite)
        print("  title: \(output.title)")
        print("  block paragraphs \(paragraphCount(block)) · main points \(mainBulletCount) · rewrite words \(totalWords) (\(block.words > 0 ? Int(Double(totalWords) / Double(block.words) * 100) : 0)% of the block) · words in bullets \(bulletsWords) (\(totalWords > 0 ? Int(Double(bulletsWords) / Double(totalWords) * 100) : 0)% of the rewrite)")
        print("  --- rewrite (\(label)) ---")
        print("  " + rewriteText.replacingOccurrences(of: "\n", with: "\n  "))
        return CallMetrics(
            label: label, paragraphCount: paragraphCount(block), mainBulletCount: mainBulletCount,
            totalRewriteWords: totalWords, bulletsWords: bulletsWords, rewriteText: rewriteText, titles: [output.title]
        )
    }

    private static func words(_ s: String?) -> Int { (s ?? "").split { $0.isWhitespace }.count }

    private static func wordCount(items: [RewriteItem]) -> Int {
        items.reduce(0) { total, item in
            total + words(item.text)
                + (item.items ?? []).reduce(0) { $0 + words($1) }
                + (item.subItems ?? []).reduce(0) { $0 + $1.reduce(0) { $0 + words($1) } }
                + (item.columns ?? []).reduce(0) { $0 + words($1) }
                + (item.rows ?? []).reduce(0) { $0 + $1.reduce(0) { $0 + words($1) } }
        }
    }

    private static func saveFixture(prompt: String, rawResponse: String, label: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/test-staging/fixtures-real", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `label` is part of the digest (an observation from the first run):
        // the user prompt is IDENTICAL for the old and the new call on the same
        // block (same `AnalysisInputBuilder.buildPrompt`; only the system
        // prompt changes, and it is not included here). Without `label` the
        // two fixtures ended up with the same file name and the second write
        // overwrote the first.
        let digest = SHA256.hash(data: Data((label + "\n" + prompt).utf8)).map { String(format: "%02x", $0) }.joined()
        let path = dir.appendingPathComponent("\(digest).json")
        try? rawResponse.write(to: path, atomically: true, encoding: .utf8)
        print("real fixture saved: \(path.path) (\(label))")
    }

    // MARK: - One document: old prompt then new prompt, on the same block

    private static func compareOldVsNew(label: String, url: URL) async throws {
        guard realCallsEnabled() else { return }
        guard let loaded = try await load(url: url) else { return }
        guard let block = pickComparisonBlock(loaded.blocks) else {
            Issue.record("\(label): no block suitable for comparison")
            return
        }
        guard let oldMetrics = await runOneCall(
            label: "\(label)-old", documentTitle: loaded.title, block: block, exhibits: loaded.exhibits,
            systemPrompt: oldSystemPrompt, schema: oldSchema, cliPath: loaded.cliPath
        ) else {
            Issue.record("\(label): call with the old prompt failed")
            return
        }
        guard let newMetrics = await runOneCall(
            label: "\(label)-new", documentTitle: loaded.title, block: block, exhibits: loaded.exhibits,
            systemPrompt: loaded.newSystemPrompt, schema: loaded.newSchema, cliPath: loaded.cliPath
        ) else {
            Issue.record("\(label): call with the new prompt failed")
            return
        }

        print("=== \(label): comparison — paragraphs \(oldMetrics.paragraphCount) · main points old \(oldMetrics.mainBulletCount) / new \(newMetrics.mainBulletCount) · % words in bullets old \(pct(oldMetrics.bulletsWords, oldMetrics.totalRewriteWords)) / new \(pct(newMetrics.bulletsWords, newMetrics.totalRewriteWords)) ===")

        // The mandatory criterion that can be automated reliably: "at least
        // 80% of the content in bullet points", on the NEW prompt (the old
        // one is the baseline for comparison and is not required to meet it).
        #expect(pct(newMetrics.bulletsWords, newMetrics.totalRewriteWords) >= 80, "\(label): only \(pct(newMetrics.bulletsWords, newMetrics.totalRewriteWords))% of the new rewrite is in bullet points (criterion: >=80%)")

        // Criterion "every paragraph has at least one corresponding point":
        // here ONLY a generous threshold against gross loss (for example 1
        // point for a block of 9 paragraphs), NOT a strict point-by-point
        // comparison with `paragraphCount`. An observation from the first
        // real run: `ParagraphBuilder`/`BlockSegmenter` (the "\n\n" separator
        // counted by `paragraphCount` above) produces a "paragraph" even for
        // a layout line break, an isolated quotation or a page boundary
        // inside continuous prose. On real PDF text this number is often 3-10
        // times the number of paragraphs a reader would perceive (observed: a
        // Wii block of 687 words/9 ParagraphBuilder paragraphs whose content,
        // spot-checked by reading, corresponds to 7 real paragraphs, all
        // covered). The strict check therefore stays the human spot-check (an
        // explicitly accepted method in the quality criteria); this single
        // automatic line only catches the pathological case (almost the whole
        // block thrown into one isolated paragraph, or a summary without
        // bullets).
        #expect(newMetrics.mainBulletCount >= 2, "\(label): a single main point for \(oldMetrics.paragraphCount) ParagraphBuilder paragraphs — possible gross loss of content, not just a different granularity")
    }

    private static func pct(_ part: Int, _ total: Int) -> Int {
        total > 0 ? Int((Double(part) / Double(total) * 100).rounded()) : 0
    }

    @Test("Merck: old/new prompt comparison on a real section")
    func merckComparison() async throws {
        try await Self.compareOldVsNew(label: "merck", url: TestPDFs.merck)
    }

    @Test("Draghi (book chapter): old/new prompt comparison on a real section")
    func draghiComparison() async throws {
        try await Self.compareOldVsNew(label: "draghi", url: TestPDFs.draghi)
    }

    @Test("Wii (HBS case): old/new prompt comparison on a real section")
    func wiiComparison() async throws {
        try await Self.compareOldVsNew(label: "wii", url: TestPDFs.wii)
    }
}
