import AppKit

/// "Copy with Formatting" (SPEC §8.1): writes to the pasteboard both the rich
/// text (RTF, for Word/Pages) and a plain-text fallback in Markdown syntax
/// (for Obsidian, consistent with `MarkdownExporter`: "- "/"  - " for
/// points/sub-points, "**...**" for emphasis, "#"/"##" for headings; the same
/// convention SPEC §8 already chose for the Obsidian export, not a new
/// format). No heading line is generated at the top (same choice as the
/// `.docx`/PDF).
///
/// `pasteboard` is a parameter (default `.general`) on purpose, for tests (a
/// test path with no save panel): the suite passes a private `NSPasteboard`,
/// never the user's real pasteboard.
@MainActor
enum RewriteCopyExporter {
    static func write(_ document: RewriteExportDocument, to pasteboard: NSPasteboard = .general, emphasizeMarkedTerms: Bool = false) {
        let attributed = RewriteExportAttributedString.build(document, emphasizeMarkedTerms: emphasizeMarkedTerms)
        guard let rtf = rtfData(for: attributed) else { return }
        let plain = plainText(for: document, emphasizeMarkedTerms: emphasizeMarkedTerms)

        pasteboard.clearContents()
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString(plain, forType: .string)
    }

    static func rtfData(for attributed: NSAttributedString) -> Data? {
        attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    // MARK: - Plain-text fallback (Markdown, for Obsidian)

    static func plainText(for document: RewriteExportDocument, emphasizeMarkedTerms: Bool = false) -> String {
        var out = ""
        for node in document.nodes {
            out += plainLine(for: node, emphasizeMarkedTerms: emphasizeMarkedTerms)
        }
        return out
    }

    private static func plainLine(for node: RewriteExportNode, emphasizeMarkedTerms: Bool) -> String {
        switch node {
        case let .heading(text, level):
            // `MarkdownExporter` convention (SPEC §8, Obsidian export):
            // chapter (level 1) = "##", section (level 2) = "###".
            return "\n\(String(repeating: "#", count: min(max(level + 1, 2), 6))) \(text)\n\n"
        case let .outlineLine(type, runsValue):
            return outlinePlainLine(type: type, runs: runsValue, emphasizeMarkedTerms: emphasizeMarkedTerms)
        case let .steps(items):
            return items.enumerated().map { "\($0 + 1). " + plainRuns($1, emphasizeMarkedTerms: emphasizeMarkedTerms) }.joined(separator: "\n") + "\n\n"
        case let .table(columns, rows):
            guard !columns.isEmpty else { return "" }
            var out = "| " + columns.joined(separator: " | ") + " |\n"
            out += "|" + columns.map { _ in " --- " }.joined(separator: "|") + "|\n"
            for row in rows {
                out += "| " + row.map { plainRuns($0, emphasizeMarkedTerms: emphasizeMarkedTerms) }.joined(separator: " | ") + " |\n"
            }
            return out + "\n"
        case let .exhibit(label):
            return "*\(label)*\n\n"
        }
    }

    /// Markdown fallback text for a `kind == .outline`/`.bullets` line. Same
    /// convention as `RewriteEditText.outlinePrefix` (Markdown reads "- "/
    /// "  - " the way Obsidian/Word expect; note, formula, consequence and
    /// subheading have no standard Markdown syntax, so they stay a text label
    /// followed by the text).
    private static func outlinePlainLine(type: RewriteLineType, runs runsValue: [RewriteExportRun], emphasizeMarkedTerms: Bool) -> String {
        switch type {
        case .point, .other:
            return "- " + plainRuns(runsValue, emphasizeMarkedTerms: emphasizeMarkedTerms) + "\n"
        case .subpoint:
            return "  - " + plainRuns(runsValue, emphasizeMarkedTerms: emphasizeMarkedTerms) + "\n"
        case .explanation:
            return "  *" + plainRuns(runsValue, emphasizeMarkedTerms: emphasizeMarkedTerms) + "*\n"
        case .consequence:
            return "- → " + plainRuns(runsValue, emphasizeMarkedTerms: emphasizeMarkedTerms) + "\n"
        case .note:
            return "> [!note] " + plainRuns(runsValue, emphasizeMarkedTerms: emphasizeMarkedTerms) + "\n"
        case .formula:
            return "> " + plainRuns(runsValue, emphasizeMarkedTerms: emphasizeMarkedTerms) + "\n"
        case .subheading:
            return "\n**" + plainRuns(runsValue, emphasizeMarkedTerms: emphasizeMarkedTerms) + "**\n"
        case .definition:
            return "> [!info] " + plainRuns(runsValue, emphasizeMarkedTerms: emphasizeMarkedTerms) + "\n"
        case .example:
            return "> [!example] " + plainRuns(runsValue, emphasizeMarkedTerms: emphasizeMarkedTerms) + "\n"
        }
    }

    private static func plainRuns(_ runsValue: [RewriteExportRun], emphasizeMarkedTerms: Bool) -> String {
        runsValue.map { (emphasizeMarkedTerms && $0.emphasis) ? "**\($0.text)**" : $0.text }.joined()
    }
}
