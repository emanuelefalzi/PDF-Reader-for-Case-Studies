import Foundation
import Testing
@testable import LelePdf

/// Input builder (SPEC §7.5 "Input"): substitution of
/// cited Exhibits, previous block summary, glossary (ordering and
/// truncation delegated to `GlossaryBuilder`, tested separately).
@Suite("AnalysisInputBuilder")
struct AnalysisInputBuilderTests {
    @Test("the block's title, section and text appear in the prompt")
    func promptContainsBasics() {
        let prompt = AnalysisInputBuilder.buildPrompt(
            documentTitle: "Documento di prova", sectionPath: ["Capitolo 1", "Sezione A"],
            previousBlockSummary: nil, glossary: [], blockCleanText: "Testo del blocco.", exhibits: []
        )
        #expect(prompt.contains("Document: Documento di prova"))
        #expect(prompt.contains("Section: Capitolo 1 > Sezione A"))
        #expect(prompt.contains("Testo del blocco."))
        #expect(!prompt.contains("Previous block summary"))
    }

    @Test("previous block summary included when present")
    func previousSummaryIncluded() {
        let prompt = AnalysisInputBuilder.buildPrompt(
            documentTitle: "T", sectionPath: [], previousBlockSummary: "Riassunto precedente.",
            glossary: [], blockCleanText: "Testo.", exhibits: []
        )
        #expect(prompt.contains("Previous block summary: Riassunto precedente."))
    }

    @Test("glossary listed with termId, term and type")
    func glossaryListed() {
        let glossary = [
            AnalysisInputBuilder.GlossaryEntry(termId: "t1", term: "FDA", type: .circle),
            AnalysisInputBuilder.GlossaryEntry(termId: "t2", term: "R&D spending", type: .rectangle),
        ]
        let prompt = AnalysisInputBuilder.buildPrompt(
            documentTitle: "T", sectionPath: [], previousBlockSummary: nil, glossary: glossary, blockCleanText: "Testo.", exhibits: []
        )
        #expect(prompt.contains("- t1: FDA (circle)"))
        #expect(prompt.contains("- t2: R&D spending (rectangle)"))
    }

    @Test("targeted regeneration includes the current rewrite and the instruction")
    func regenerationPromptIncludesCurrentRewriteAndInstruction() {
        let prompt = AnalysisInputBuilder.buildRegenerationPrompt(
            documentTitle: "T", sectionPath: [], previousBlockSummary: nil, glossary: [],
            blockCleanText: "Testo.", exhibits: [], currentRewritePlainText: "Riscrittura attuale.",
            instruction: "Più breve"
        )
        #expect(prompt.contains("Current rewrite:\nRiscrittura attuale."))
        #expect(prompt.contains("Instruction: Più breve"))
    }

    // MARK: - previousBlockSummary (pure)

    private func block(_ id: String) -> TextBlock {
        TextBlock(id: id, sectionPath: ["Sezione"], pageStart: 0, pageEnd: 0, cleanText: "testo", textHash: id, words: 10, spans: [], lineRectsByPage: [:])
    }

    @Test("no previous block: nil")
    func noPreviousBlock() {
        let blocks = [block("b1"), block("b2")]
        let summary = AnalysisInputBuilder.previousBlockSummary(blocks: blocks, analysis: AnalysisRecord(), blockId: "b1")
        #expect(summary == nil)
    }

    @Test("previous block not analyzed: nil")
    func previousBlockNotAnalyzed() {
        let blocks = [block("b1"), block("b2")]
        let summary = AnalysisInputBuilder.previousBlockSummary(blocks: blocks, analysis: AnalysisRecord(), blockId: "b2")
        #expect(summary == nil)
    }

    @Test("previous block analyzed: summary taken from the first summary item")
    func previousBlockAnalyzedReturnsSummary() {
        let blocks = [block("b1"), block("b2")]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, rewrite: [
            RewriteItem(kind: .summary, text: "Riassunto di b1."),
            RewriteItem(kind: .paragraph, text: "Altro testo."),
        ])
        let summary = AnalysisInputBuilder.previousBlockSummary(blocks: blocks, analysis: analysis, blockId: "b2")
        #expect(summary == "Riassunto di b1.")
    }

    /// Fix: a summary with `{{mX|words}}` markers (SPEC §7.5 item 12) must
    /// not carry them, as they are, into the next block's prompt — found with a
    /// real call during visual verification.
    @Test("the previous block's summary arrives stripped of markers")
    func previousBlockSummaryStripsMarkers() {
        let blocks = [block("b1"), block("b2")]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, rewrite: [
            RewriteItem(kind: .summary, text: "{{m3|Merck & Co.}} named {{m1|Richard Clark}} CEO in 2005."),
        ])
        let summary = AnalysisInputBuilder.previousBlockSummary(blocks: blocks, analysis: analysis, blockId: "b2")
        #expect(summary == "Merck & Co. named Richard Clark CEO in 2005.")

        // And consequently the whole prompt no longer contains `{{` either.
        let prompt = AnalysisInputBuilder.buildPrompt(
            documentTitle: "T", sectionPath: [], previousBlockSummary: summary, glossary: [], blockCleanText: "Testo.", exhibits: []
        )
        #expect(!prompt.contains("{{"))
    }

    // MARK: - ExhibitCitationSubstitution (pure)

    @Test("a citation with a match is replaced with [label, p. N]")
    func exhibitCitationSubstituted() {
        let text = "Come mostrato in Exhibit 5, i ricavi sono cresciuti."
        let exhibits = [ExhibitRef(label: "Exhibit 5", page: 18)]
        let result = ExhibitCitationSubstitution.substitute(in: text, exhibits: exhibits)
        #expect(result == "Come mostrato in [Exhibit 5, p. 19], i ricavi sono cresciuti.")
    }

    @Test("a citation without a match is left intact")
    func exhibitCitationWithoutMatchLeftAlone() {
        let text = "Vedi Figure 9 per il dettaglio."
        let exhibits = [ExhibitRef(label: "Exhibit 5", page: 18)]
        let result = ExhibitCitationSubstitution.substitute(in: text, exhibits: exhibits)
        #expect(result == text)
    }

    @Test("an optional letter after the number (e.g. 5A) is recognized and replaced")
    func exhibitCitationWithLetterSuffix() {
        let text = "Si veda Table 2A."
        let exhibits = [ExhibitRef(label: "Table 2", page: 4)]
        let result = ExhibitCitationSubstitution.substitute(in: text, exhibits: exhibits)
        #expect(result == "Si veda [Table 2A, p. 5].")
    }

    @Test("case-insensitive search")
    func exhibitCitationCaseInsensitive() {
        let text = "come mostrato in exhibit 5."
        let exhibits = [ExhibitRef(label: "Exhibit 5", page: 18)]
        let result = ExhibitCitationSubstitution.substitute(in: text, exhibits: exhibits)
        #expect(result == "come mostrato in [exhibit 5, p. 19].")
    }

    // MARK: - F8: density line

    @Test("Paragraph/Heading 3: no density line (current behavior, unchanged)")
    func noDensityLineForFinerGranularities() {
        #expect(AnalysisInputBuilder.densityLine(granularity: .paragraph, blockWords: 5000) == nil)
        #expect(AnalysisInputBuilder.densityLine(granularity: .heading3, blockWords: 5000) == nil)
        let prompt = AnalysisInputBuilder.buildPrompt(
            documentTitle: "T", sectionPath: [], previousBlockSummary: nil, glossary: [], blockCleanText: "Testo.",
            exhibits: [], granularity: .heading3, blockWords: 690
        )
        #expect(!prompt.contains("Summary granularity"))
    }

    @Test("Heading 2/Chapter: density line with the points target, in the real input")
    func densityLineIncludedForWiderGranularities() {
        let densityHeading2 = AnalysisInputBuilder.densityLine(granularity: .heading2, blockWords: 1200)
        #expect(densityHeading2?.contains("Summary granularity: Heading 2") == true)
        #expect(densityHeading2?.contains("Target outline size") == true)

        let prompt = AnalysisInputBuilder.buildPrompt(
            documentTitle: "T", sectionPath: [], previousBlockSummary: nil, glossary: [], blockCleanText: "Testo.",
            exhibits: [], granularity: .chapter, blockWords: 2600
        )
        #expect(prompt.contains("Summary granularity: Chapter (Heading 1)"))
        #expect(prompt.contains("Target outline size"))
    }

    @Test("the points target grows with the block length, within the stated bounds")
    func targetOutlinePointsScalesWithWordsWithinBounds() {
        #expect(SummaryGranularity.chapter.targetOutlinePoints(forBlockWords: 100) == 6) // minimum
        #expect(SummaryGranularity.chapter.targetOutlinePoints(forBlockWords: 10_000) == 20) // maximum
        #expect(SummaryGranularity.chapter.targetOutlinePoints(forBlockWords: 2000) == 10) // 2000/200
        #expect(SummaryGranularity.heading2.targetOutlinePoints(forBlockWords: 100) == 4)
        #expect(SummaryGranularity.heading2.targetOutlinePoints(forBlockWords: 10_000) == 12)
    }
}
