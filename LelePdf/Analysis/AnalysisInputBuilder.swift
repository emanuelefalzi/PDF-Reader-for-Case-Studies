import Foundation

/// Builds the user input for the analysis (SPEC §7.5 "Input", §7.6): pure and
/// testable, no dependency on `BatchRunner`/PDFKit. `AnalysisQueue` and
/// `AnalysisController.regenerate` call it with data already gathered by the
/// caller.
enum AnalysisInputBuilder {
    /// Glossary entry (SPEC §7.5: "termId, term, mark type"), already sorted
    /// and cut to 60 by `GlossaryBuilder`.
    struct GlossaryEntry: Sendable, Equatable {
        var termId: String
        var term: String
        var type: MarkType
    }

    /// First analysis of a block (SPEC §7.5 Input). `granularity`/`blockWords`
    /// are passed for the optional density line (`densityLine`); `nil`/`0` for
    /// a caller that does not know them yet (no line added, same input as
    /// before).
    static func buildPrompt(
        documentTitle: String,
        sectionPath: [String],
        previousBlockSummary: String?,
        glossary: [GlossaryEntry],
        blockCleanText: String,
        exhibits: [ExhibitRef],
        granularity: SummaryGranularity = .heading3,
        blockWords: Int = 0
    ) -> String {
        var lines = header(documentTitle: documentTitle, sectionPath: sectionPath, previousBlockSummary: previousBlockSummary, glossary: glossary, granularity: granularity, blockWords: blockWords)
        lines.append("")
        lines.append("Block text:")
        lines.append(ExhibitCitationSubstitution.substitute(in: blockCleanText, exhibits: exhibits))
        return lines.joined(separator: "\n")
    }

    /// Targeted regeneration (SPEC §7.6): the same input plus the current
    /// rewrite (plain text, markers already resolved) and the instruction.
    static func buildRegenerationPrompt(
        documentTitle: String,
        sectionPath: [String],
        previousBlockSummary: String?,
        glossary: [GlossaryEntry],
        blockCleanText: String,
        exhibits: [ExhibitRef],
        currentRewritePlainText: String,
        instruction: String,
        granularity: SummaryGranularity = .heading3,
        blockWords: Int = 0
    ) -> String {
        var lines = header(documentTitle: documentTitle, sectionPath: sectionPath, previousBlockSummary: previousBlockSummary, glossary: glossary, granularity: granularity, blockWords: blockWords)
        lines.append("")
        lines.append("Block text:")
        lines.append(ExhibitCitationSubstitution.substitute(in: blockCleanText, exhibits: exhibits))
        lines.append("")
        lines.append("Current rewrite:")
        lines.append(currentRewritePlainText)
        lines.append("")
        lines.append("Instruction: \(instruction)")
        return lines.joined(separator: "\n")
    }

    private static func header(
        documentTitle: String, sectionPath: [String], previousBlockSummary: String?, glossary: [GlossaryEntry],
        granularity: SummaryGranularity, blockWords: Int
    ) -> [String] {
        var lines = ["Document: \(documentTitle)"]
        if !sectionPath.isEmpty {
            lines.append("Section: \(sectionPath.joined(separator: " > "))")
        }
        if let previousBlockSummary, !previousBlockSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Previous block summary: \(previousBlockSummary)")
        }
        if let density = densityLine(granularity: granularity, blockWords: blockWords) {
            lines.append(density)
        }
        if !glossary.isEmpty {
            lines.append("Glossary:")
            for entry in glossary {
                lines.append("- \(entry.termId): \(entry.term) (\(entry.type.rawValue))")
            }
        }
        return lines
    }

    /// Prompt density: for a granularity wider than a section
    /// (`heading2`/`chapter`) the block can cover many paragraphs, so the old
    /// "one point per paragraph" (`analysis.md` rule 4) would produce a very
    /// long outline. This input line gives Claude an EXPLICIT density target,
    /// consistent with the block's real length
    /// (`SummaryGranularity.targetOutlinePoints`); `nil` for
    /// `paragraph`/`heading3` (today's verified behavior, unchanged: one point
    /// per paragraph remains the rule).
    static func densityLine(granularity: SummaryGranularity, blockWords: Int) -> String? {
        guard let target = granularity.targetOutlinePoints(forBlockWords: blockWords) else { return nil }
        return "Summary granularity: \(granularity.label) -- this block covers roughly \(blockWords) words across several paragraphs. Target outline size: about \(target) top-level points total. Group related paragraphs under fewer, denser points instead of one point per paragraph; keep only the most important subpoints."
    }

    /// Summary of the previous block, if already analyzed (SPEC §7.5 Input):
    /// the block immediately before in the document's block order (`blocks`,
    /// not the queue order). `nil` if there is no block before, if it is not
    /// analyzed yet, or if it has no `summary` item.
    ///
    /// Fix found during visual verification with a real call:
    /// `rewrite[].text` can contain `{{mX|shown words}}` markers (SPEC §7.5
    /// point 12). Without cleaning them before putting them in the prompt,
    /// "Previous block summary:" reached Claude with the marker syntax still
    /// inside (verified with a real call on block 1.2 of the Merck case), a
    /// format the system prompt does not document as expected for that field.
    /// `RewritePlainText.render` (used for "Current rewrite:" in targeted
    /// regeneration, SPEC §7.6) already stripped markers from the text sent
    /// back to Claude; here the same treatment was missing, and it uses the
    /// same pure function (`MarkerSanitizer.sanitize`, no "kept" ids: a past
    /// summary never carries drawable marks with it).
    static func previousBlockSummary(blocks: [TextBlock], analysis: AnalysisRecord, blockId: String) -> String? {
        guard let index = blocks.firstIndex(where: { $0.id == blockId }), index > 0 else { return nil }
        let previousId = blocks[index - 1].id
        guard let previousAnalysis = analysis.blocks[previousId], previousAnalysis.status == .analyzed,
              let summaryText = previousAnalysis.rewrite.first(where: { $0.kind == .summary })?.text else { return nil }
        return MarkerSanitizer.sanitize(summaryText, keptMarkIds: [])
    }
}
