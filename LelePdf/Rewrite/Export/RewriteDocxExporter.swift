import Foundation

/// "Word (.docx)" (SPEC §8.2): a real OOXML package, built with Foundation
/// plus `MinimalZipWriter` (no external dependencies).
///
/// No direct formatting in `document.xml` by default: `word/document.xml`
/// writes ONLY `<w:pStyle>` for each paragraph, with no direct
/// `w:numPr`/indents/colors for point/sub-point/note/formula/consequence/
/// subheading (both the built-in template and the one chosen by the user,
/// `RewriteDocxTemplateStore`, carry the numbering INSIDE the style
/// definition itself), and no direct `<w:b/>` for a marked term:
/// `emphasizeMarkedTerms` (defaults to `false`,
/// `WordTemplateSettings.emphasizeMarkedTerms()`) instead references the
/// CHARACTER style `IntenseEmphasis` (`<w:rStyle>`) when it is on, never a
/// `<w:rPr><w:b/></w:rPr>` on the run. `steps`/`table` (rows left over for an
/// analysis saved before the outline format) remain the exception: no
/// template defines them, so only `steps` still carries an explicit `w:numPr`
/// (`RewriteDocxDefaultTemplate.stepsNumId`, always included by
/// `RewriteDocxTemplateStore`), while `table` uses the "List Paragraph" style
/// without numbering (it is not a real list).
///
/// Neither `NSAttributedString(... officeOpenXML)` nor a third-party engine is
/// used.
///
/// Pure: `export(for:templateDirectory:emphasizeMarkedTerms:)` does not touch
/// the save panel; only `RewriteDocxTemplateStore.resolve` reads the chosen
/// template's folder (Application Support or a test folder), and nothing
/// reads the user's PDFs or Desktop.
enum RewriteDocxExporter {
    /// Missing style -> nearest built-in style, reported: the caller
    /// (`RewriteExportController`) shows `fallbacksUsed`/
    /// `customTemplateUnreadable` to the user after saving.
    struct Result: Sendable {
        var data: Data
        var fallbacksUsed: [RewriteDocxStyle]
        var customTemplateUnreadable: Bool
    }

    static func export(for document: RewriteExportDocument, templateDirectory: URL?, emphasizeMarkedTerms: Bool = false) -> Result {
        let resolved = RewriteDocxTemplateStore.resolve(customTemplateDirectory: templateDirectory)
        var entries: [MinimalZipWriter.Entry] = resolved.entries.map { .init(path: $0.key, data: $0.value) }
        entries.append(.init(
            path: "word/document.xml",
            data: Data(documentXML(for: document, styleMap: resolved.styleMap, emphasizeMarkedTerms: emphasizeMarkedTerms).utf8)
        ))
        return Result(
            data: MinimalZipWriter.makeArchive(entries: entries),
            fallbacksUsed: resolved.fallbacksUsed, customTemplateUnreadable: resolved.customTemplateUnreadable
        )
    }

    /// Convenience for tests that verify only the XML STRUCTURE (no need for
    /// the template/package): uses the built-in template.
    static func data(for document: RewriteExportDocument, templateDirectory: URL? = nil, emphasizeMarkedTerms: Bool = false) -> Data {
        export(for: document, templateDirectory: templateDirectory, emphasizeMarkedTerms: emphasizeMarkedTerms).data
    }

    // MARK: - word/document.xml

    /// No generated header (no `Title`/`Subtitle` "Document · Section ·
    /// pages"): the body starts directly with the document's nodes.
    static func documentXML(for document: RewriteExportDocument, styleMap: RewriteDocxStyleMap = .builtIn, emphasizeMarkedTerms: Bool = false) -> String {
        var body = ""
        for node in document.nodes {
            body += xml(for: node, styleMap: styleMap, emphasizeMarkedTerms: emphasizeMarkedTerms)
        }
        body += "<w:sectPr/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(body)</w:body>
        </w:document>
        """
    }

    /// T1-T4 -> `Heading1`-`Heading4` (the level comes from the document's
    /// contents, not from Claude); without `Heading4` in the active template,
    /// T4 falls back to `Heading3`. This is the only fallback rule that does
    /// NOT go through `RewriteDocxTemplateStore`/style injection ("or Heading4
    /// if present in the template" implies no patching).
    static func headingStyleId(level: Int, styleMap: RewriteDocxStyleMap) -> String {
        switch min(max(level, 1), 4) {
        case 1: return styleMap.id(for: .heading1)
        case 2: return styleMap.id(for: .heading2)
        case 3: return styleMap.id(for: .heading3)
        default: return styleMap.has(.heading4) ? styleMap.id(for: .heading4) : styleMap.id(for: .heading3)
        }
    }

    private static func xml(for node: RewriteExportNode, styleMap: RewriteDocxStyleMap, emphasizeMarkedTerms: Bool) -> String {
        // The character style of marked terms is the template's REAL one
        // (found by id or by name), `nil` with the option off.
        let markedTermStyle: String? = emphasizeMarkedTerms ? styleMap.id(for: .markedTerm) : nil
        switch node {
        case let .heading(text, level):
            return paragraph(style: headingStyleId(level: level, styleMap: styleMap), runs: [RewriteExportRun(text: text)], markedTermStyle: markedTermStyle)
        case let .outlineLine(type, runsValue):
            // ONLY `w:pStyle`, no direct paragraph formatting; the numbering
            // of point/sub-point/consequence lives in the style itself.
            return paragraph(style: styleMap.id(for: RewriteDocxStyle.style(for: type)), runs: runsValue, markedTermStyle: markedTermStyle)
        case let .steps(items):
            return items.map { listParagraph(runs: $0, numId: RewriteDocxDefaultTemplate.stepsNumId, markedTermStyle: markedTermStyle) }.joined()
        case let .table(columns, rows):
            // "List Paragraph" instead of "Normal". A real OOXML grid is still
            // out of scope; only the paragraph style changes here. No forced
            // bold header any more (direct formatting not gated by the
            // option).
            var out = paragraph(style: RewriteDocxDefaultTemplate.listParagraphStyleId, runs: [RewriteExportRun(text: columns.joined(separator: "   ·   "))], markedTermStyle: markedTermStyle)
            for row in rows {
                let cells = row.map { cell in cell.map(\.text).joined() }
                out += paragraph(style: RewriteDocxDefaultTemplate.listParagraphStyleId, runs: [RewriteExportRun(text: cells.joined(separator: "   ·   "))], markedTermStyle: markedTermStyle)
            }
            return out
        case let .exhibit(label):
            return paragraph(style: styleMap.id(for: .note), runs: [RewriteExportRun(text: label)], markedTermStyle: markedTermStyle)
        }
    }

    private static func paragraph(style: String, runs: [RewriteExportRun], markedTermStyle: String?) -> String {
        "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>\(runsXML(runs, markedTermStyle: markedTermStyle))</w:p>"
    }

    /// Only `steps` (rows left over for an analysis saved before the outline
    /// format) still carries an explicit `w:numPr` on the paragraph; see the
    /// comment at the top of the file.
    private static func listParagraph(runs: [RewriteExportRun], numId: Int, markedTermStyle: String?) -> String {
        """
        <w:p><w:pPr><w:pStyle w:val="\(RewriteDocxDefaultTemplate.listParagraphStyleId)"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="\(numId)"/></w:numPr></w:pPr>\(runsXML(runs, markedTermStyle: markedTermStyle))</w:p>
        """
    }

    /// A marked term (`run.emphasis`) references the CHARACTER style
    /// `IntenseEmphasis` ONLY if `emphasizeMarkedTerms` is true, which
    /// defaults to `false` (no patching here: `RewriteDocxTemplateStore`
    /// guarantees the styleId always exists, silently injected if the chosen
    /// template lacks it). Never a direct `<w:b/>` on the run.
    private static func runsXML(_ runs: [RewriteExportRun], markedTermStyle: String?) -> String {
        guard !runs.isEmpty else { return "" }
        return runs.map { run -> String in
            let text = RewriteDocxTemplates.escapeXML(run.text)
            let rPr = (markedTermStyle != nil && run.emphasis) ? "<w:rPr><w:rStyle w:val=\"\(markedTermStyle ?? "")\"/></w:rPr>" : ""
            return "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
        }.joined()
    }
}
