import Foundation
import Testing
@testable import LelePdf

/// API consumed by the card panel (M5a): "Continue with
/// the next" (formerly "Resume from"), segments in document order, resolved
/// card, targeted regeneration (manual marks kept, Claude marks replaced).
///
/// Not `@MainActor` at struct level (unlike `AnalysisController`, which
/// is): the regeneration test uses `withClaudeTestEnv`, which takes a
/// generic non-isolated closure — see the comment in
/// `AnalysisQueueTests.swift` for the reason. Every controller access
/// goes through `await MainActor.run { ... }`; the `async` calls isolated
/// to the MainActor (`regenerate`) remain a plain `await`.
@Suite("AnalysisController")
struct AnalysisControllerTests {
    private func tempStore() throws -> (store: DocumentStore, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfAnalysisControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DocumentStore(dataFolderURL: dir), { try? FileManager.default.removeItem(at: dir) })
    }

    private func block(_ id: String, page: Int, text: String = "Testo di prova.") -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id, words: 4, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    /// Like `block(_:page:)`, but with `partIndex`/`partCount` (a long
    /// section split into several parts — see the continuation-part test below).
    private func partBlock(_ id: String, page: Int, partIndex: Int, partCount: Int, text: String = "Testo di prova.") -> TextBlock {
        var b = block(id, page: page, text: text)
        b.partIndex = partIndex
        b.partCount = partCount
        return b
    }

    // MARK: - "Continue with the next"

    @Test("Continue with the next: next unanalyzed block after the reading position, with a human-readable label")
    @MainActor
    func continueLabelUsesReadingPosition() throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let controller = AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!)

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed)
        controller.updateContext(
            fingerprint: "fp", documentTitle: "T", blocks: [block("b1", page: 0), block("b2", page: 1)],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b1", tocEntries: []
        )
        #expect(controller.continueLabel(currentPageIndex: 0) == "0.2")
        #expect(controller.continueBlockId(currentPageIndex: 0) == "b2")
    }

    @Test("Continue with the next: nil when all blocks are analyzed")
    @MainActor
    func continueLabelNilWhenAllAnalyzed() throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let controller = AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!)
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed)
        controller.updateContext(fingerprint: "fp", documentTitle: "T", blocks: [block("b1", page: 0)], exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b1", tocEntries: [])
        #expect(controller.continueLabel(currentPageIndex: 0) == nil)
    }

    /// **Real bug reported by the user**: "the references are a bit off, it
    /// almost seems fixed on 2.4 and not relative to the paragraph".
    /// Reproduction: analyze a distant block out of order (here "b4", via the
    /// selection bar or a card), then read elsewhere in the document. With the
    /// old `resumeBlockId` (anchored to `lastAnalyzedBlockId == "b4"`) the
    /// suggestion would have stayed IDENTICAL ("b2", the first unanalyzed
    /// block of the document) whatever the current page — what the user
    /// describes as "fixed". With `continueBlockId`, anchored to the real
    /// reading position, the suggestion moves along with the reader.
    @Test("Continue with the next: follows the reading position, does not stay fixed on the last block analyzed out of order")
    @MainActor
    func continueBlockFollowsReadingPositionNotLastAnalyzedOutOfOrder() throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let controller = AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!)

        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed)
        analysis.blocks["b4"] = BlockAnalysis(status: .analyzed) // analyzed out of order, last
        let blocks = [block("b1", page: 0), block("b2", page: 1), block("b3", page: 2), block("b4", page: 3), block("b5", page: 4)]
        controller.updateContext(
            fingerprint: "fp", documentTitle: "T", blocks: blocks,
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: "b4", tocEntries: []
        )

        // Reading near the start: the next one to suggest is "b2".
        #expect(controller.continueBlockId(currentPageIndex: 0) == "b2")

        // Scrolling to the block just analyzed out of order ("b4", page 3), the
        // suggestion moves to the next block, "b5" — direct proof that it does NOT
        // stay fixed on "b2".
        #expect(controller.continueBlockId(currentPageIndex: 3) == "b5")
    }

    // MARK: - Segments in document order

    @Test("segments interleaved by page: headings, blocks, Exhibits")
    @MainActor
    func documentOrderSegmentsInterleavedByPage() throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let controller = AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!)
        let toc = [TocEntry(id: "c1", title: "Capitolo 1", level: 1, page: 0)]
        controller.updateContext(
            fingerprint: "fp", documentTitle: "T", blocks: [block("b1", page: 0), block("b2", page: 2)],
            exhibits: [ExhibitRef(label: "Exhibit 1", page: 1)], analysis: AnalysisRecord(), lastAnalyzedBlockId: nil, tocEntries: toc
        )
        let segments = controller.documentOrderSegments()
        #expect(segments == [
            .heading(title: "Capitolo 1", level: 1, page: 0),
            .block(blockId: "b1"),
            .exhibit(label: "Exhibit 1", page: 1),
            .block(blockId: "b2"),
        ])
    }

    /// **Real bug reported by the user**: "on the right ... it writes part 3/3
    /// correctly, but it puts it after the title of the next section".
    /// Reproduction: Section A is split into 3 parts; part 3 ends on the SAME
    /// page where Section B's title starts (part 3 occupies the top of the
    /// page, the next section's title starts lower on the same page — a
    /// plausible case with short sections/dense pages). The rule "headings
    /// always before blocks on the same page" alone promoted B's title above
    /// "3.2 · part 3 of 3" (Section A, still open): part 3 ALWAYS goes before a
    /// heading tied on the same page; a first part/a whole block (no split)
    /// does not.
    @Test("segments: a continuation part always precedes the next section's heading on the same page")
    @MainActor
    func continuationPartPrecedesNextSectionHeadingOnSamePage() throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let controller = AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!)
        let toc = [
            TocEntry(id: "c1", title: "Sezione A", level: 1, page: 0),
            TocEntry(id: "c2", title: "Sezione B", level: 1, page: 2),
        ]
        let blocks = [
            partBlock("a1", page: 0, partIndex: 1, partCount: 3),
            partBlock("a2", page: 1, partIndex: 2, partCount: 3),
            partBlock("a3", page: 2, partIndex: 3, partCount: 3), // same page as B's heading
            block("b1", page: 2), // first (and only) block of Section B, same page as its heading
        ]
        controller.updateContext(
            fingerprint: "fp", documentTitle: "T", blocks: blocks,
            exhibits: [], analysis: AnalysisRecord(), lastAnalyzedBlockId: nil, tocEntries: toc
        )
        let segments = controller.documentOrderSegments()
        #expect(segments == [
            .heading(title: "Sezione A", level: 1, page: 0),
            .block(blockId: "a1"),
            .block(blockId: "a2"),
            .block(blockId: "a3"),
            .heading(title: "Sezione B", level: 1, page: 2),
            .block(blockId: "b1"),
        ])
    }

    // MARK: - Resolved card

    @Test("card: a valid marker becomes a marked segment, an unknown id stays plain text")
    @MainActor
    func cardDataResolvesMarkers() throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let controller = AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!)
        var analysis = AnalysisRecord()
        let mark = Mark(id: "m1", termId: "t1", type: .rectangle, text: "FDA", source: .claude, page: 0, range: MarkRange(start: 0, length: 3))
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Titolo",
            rewrite: [RewriteItem(kind: .summary, text: "{{m1|FDA}} ha deciso.")],
            marks: [mark]
        )
        controller.updateContext(fingerprint: "fp", documentTitle: "T", blocks: [block("b1", page: 0)], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])

        let card = try #require(controller.cardData(for: "b1"))
        let segments = try #require(card.rewrite.first?.segments)
        #expect(segments == [.marked(text: "FDA", markId: "m1", termId: "t1", type: .rectangle), .plain(" ha deciso.")])
    }

    // MARK: - Targeted regeneration (SPEC §7.6)

    @Test("regeneration: replaces Claude's marks, keeps the manual ones")
    func regenerateReplacesClaudeMarksKeepsManual() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp-regen"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)

        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let text = "Il farmaco riduce i costi in modo netto."
            let manualMark = Mark(id: "manual-1", termId: "t-manual", type: .circle, text: "farmaco", source: .manual, page: 0, range: MarkRange(start: 3, length: 7))
            let oldClaudeMark = Mark(id: "old-claude-1", termId: "t-old", type: .rectangle, text: "costi", source: .claude, page: 0, range: MarkRange(start: 20, length: 5))
            var analysis = AnalysisRecord()
            analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, title: "Vecchio", rewrite: [RewriteItem(kind: .paragraph, text: "Vecchia riscrittura.")], marks: [manualMark, oldClaudeMark])

            let controller = await MainActor.run { AnalysisController(store: store, runner: BatchRunner(timeout: 10), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!) }
            let block = block("b1", page: 0, text: text)
            await MainActor.run {
                controller.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [block], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
            }

            let result = await controller.regenerate(blockId: "b1", instruction: "Più breve")
            guard case .success = result else {
                Issue.record("expected .success, found \(result)")
                return
            }

            let updated = await MainActor.run { controller.context?.analysis.blocks["b1"] }
            let unwrapped = try #require(updated)
            #expect(unwrapped.marks.contains { $0.id == "manual-1" }) // manual one kept
            #expect(!unwrapped.marks.contains { $0.id == "old-claude-1" }) // old Claude mark replaced
            #expect(unwrapped.marks.contains { $0.source == .claude }) // new Claude marks present (fake CLI)
            #expect(unwrapped.title != "Vecchio") // new response from the fake CLI
        }
    }
}
