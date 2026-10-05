import AppKit

/// Builds the `NSAttributedString` shared by "Copy with Formatting"
/// (`RewriteCopyExporter`) and the PDF (`RewritePDFExporter`): a single source
/// of style for the two formats that go through TextKit, so headings, points
/// and sub-points stay identical between them (SPEC §8.2 "same structure"),
/// and match the structure of the `.docx` (`RewriteDocxExporter` reads the
/// same `RewriteExportDocument`).
///
/// No heading is generated (no "Document · Section · pages" line at the top),
/// the same choice as the `.docx`.
///
/// Points/sub-points: a literal "•"/"◦" prefix plus indentation
/// (`headIndent`/`firstLineHeadIndent`) instead of `NSTextList`. An
/// `NSTextList` exported to RTF depends on how well the application that
/// reopens it interprets RTF lists (it varies between Word/Pages/TextEdit),
/// whereas a literal prefix with indentation is plain text and a plain
/// paragraph: it looks identical everywhere, can be verified with a direct
/// comparison of `attributedString.string` in tests, and is still "points and
/// sub-points" for all purposes (SPEC §8.1). The real Word file (.docx)
/// instead has a genuine OOXML list: see `RewriteDocxExporter`.
@MainActor
enum RewriteExportAttributedString {
    private static let bodyFont = NSFont(name: "Helvetica", size: 11.5) ?? .systemFont(ofSize: 11.5)
    private static let boldFont = NSFont(name: "Helvetica-Bold", size: 11.5) ?? .boldSystemFont(ofSize: 11.5)
    private static let italicFont = NSFont(name: "Helvetica-Oblique", size: 10) ?? .systemFont(ofSize: 10)
    /// Italic for note/explanation: normal body text in italic. Not
    /// `italicFont` above (10 pt, meant for the old "Ch. · pages" header line,
    /// since removed), but the same size as the body.
    private static let bodyItalicFont = NSFont(name: "Helvetica-Oblique", size: 11.5) ?? .systemFont(ofSize: 11.5)
    /// Italic serif, to make the `formula` line stand out even without reading
    /// its text; same idea as `RewriteLineRowView`/`MarkedNSTextView.baseFont`
    /// in the panel.
    private static let formulaFont = NSFont(name: "Times-Italic", size: 11.5) ?? .systemFont(ofSize: 11.5)
    private static let subheadingFont = NSFont(name: "Helvetica-Bold", size: 11.5) ?? .boldSystemFont(ofSize: 11.5)
    /// Example: a bit smaller than the body and in italic (Word style
    /// `Example`: italic, dark gray, 10 pt).
    private static let exampleFont = NSFont(name: "Helvetica-Oblique", size: 10.5) ?? .systemFont(ofSize: 10.5)
    /// Colors of the left bars of the `Definizione`/`Example` styles of the
    /// user's Word template (blue-green 156082, dark gray 3A3A3A).
    private static let definitionBarColor = NSColor(srgbRed: 0.086, green: 0.376, blue: 0.510, alpha: 1)
    private static let exampleBarColor = NSColor(srgbRed: 0.227, green: 0.227, blue: 0.227, alpha: 1)

    private static func headingFont(level: Int) -> NSFont {
        NSFont(name: "Helvetica-Bold", size: level <= 1 ? 17 : 14) ?? .boldSystemFont(ofSize: level <= 1 ? 17 : 14)
    }

    /// `emphasizeMarkedTerms` (defaults to `false`,
    /// `WordTemplateSettings.emphasizeMarkedTerms()`): a marked term
    /// (`run.emphasis`) becomes bold ONLY when it is on. It is the same
    /// preference `RewriteDocxExporter` uses for the character style; here it
    /// is simply a bold font (RTF/PDF have no named styles like OOXML).
    static func build(_ document: RewriteExportDocument, emphasizeMarkedTerms: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for node in document.nodes {
            result.append(paragraph(for: node, emphasizeMarkedTerms: emphasizeMarkedTerms))
        }
        return result
    }

    private static func paragraph(for node: RewriteExportNode, emphasizeMarkedTerms: Bool) -> NSAttributedString {
        switch node {
        case let .heading(text, level):
            return line(text, font: headingFont(level: level), spacingBefore: 10, spacingAfter: 4)
        case let .outlineLine(type, runsValue):
            return outlineLineParagraph(type: type, runs: runsValue, emphasizeMarkedTerms: emphasizeMarkedTerms)
        case let .steps(items):
            let out = NSMutableAttributedString()
            for (index, itemRuns) in items.enumerated() {
                out.append(bulletParagraph(itemRuns, marker: "\(index + 1).", indent: 14, emphasizeMarkedTerms: emphasizeMarkedTerms))
            }
            return out
        case let .table(columns, rows):
            return tableParagraph(columns: columns, rows: rows)
        case let .exhibit(label):
            return line(label, font: italicFont, indent: 0, spacingAfter: 6)
        }
    }

    // MARK: - Paragraph helpers

    private static func paragraphStyle(indent: CGFloat, hanging: CGFloat = 0, spacingBefore: CGFloat = 2, spacingAfter: CGFloat = 6) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = max(0, indent - hanging)
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        return style
    }

    private static func line(_ text: String, font: NSFont, indent: CGFloat = 0, spacingBefore: CGFloat = 2, spacingAfter: CGFloat = 6) -> NSAttributedString {
        let style = paragraphStyle(indent: indent, spacingBefore: spacingBefore, spacingAfter: spacingAfter)
        return NSAttributedString(string: text + "\n", attributes: [.font: font, .paragraphStyle: style])
    }

    /// `font`: replaces the default `bodyFont`/`boldFont` (note/explanation/
    /// subheading lines with a typeface different from the body). A marked run
    /// inside stays distinguishable, bold on top of the given font, only if
    /// `emphasizeMarkedTerms` is on.
    private static func runsParagraph(_ runsValue: [RewriteExportRun], indent: CGFloat, font: NSFont? = nil, emphasizeMarkedTerms: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base = font ?? bodyFont
        let emphasized = font.map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) } ?? boldFont
        for run in runsValue {
            out.append(NSAttributedString(string: run.text, attributes: [.font: (emphasizeMarkedTerms && run.emphasis) ? emphasized : base]))
        }
        out.append(NSAttributedString(string: "\n"))
        out.addAttribute(.paragraphStyle, value: paragraphStyle(indent: indent), range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Point/sub-point/numbered step with a hanging indent (SPEC §8.1 "points
    /// and sub-points", maximum depth 2): the marker ("•", "◦" or "1.") stays
    /// aligned at `indent - hangingWidth`, the text (even over several lines)
    /// stays aligned at `indent`.
    private static func bulletParagraph(_ runsValue: [RewriteExportRun], marker: String, indent: CGFloat, markerColor: NSColor? = nil, font: NSFont? = nil, emphasizeMarkedTerms: Bool) -> NSAttributedString {
        let base = font ?? bodyFont
        var markerAttributes: [NSAttributedString.Key: Any] = [.font: bodyFont]
        if let markerColor { markerAttributes[.foregroundColor] = markerColor }
        let out = NSMutableAttributedString(string: marker + "\u{9}", attributes: markerAttributes)
        let emphasized = font.map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) } ?? boldFont
        for run in runsValue {
            out.append(NSAttributedString(string: run.text, attributes: [.font: (emphasizeMarkedTerms && run.emphasis) ? emphasized : base]))
        }
        out.append(NSAttributedString(string: "\n"))
        let style = paragraphStyle(indent: indent, hanging: 14)
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.defaultTabInterval = indent
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// One paragraph per `kind == .outline`/`.bullets` line
    /// (`RewriteExportNode.outlineLine`), with the same visual language as the
    /// right-hand panel (`RewriteLineRowView`), adapted to RTF/PDF: marker plus
    /// indent for point/sub-point/consequence, italic for note/explanation,
    /// italic serif for formula, bold for subheading.
    private static func outlineLineParagraph(type: RewriteLineType, runs runsValue: [RewriteExportRun], emphasizeMarkedTerms: Bool) -> NSAttributedString {
        switch type {
        case .point, .other:
            return bulletParagraph(runsValue, marker: "•", indent: 14, emphasizeMarkedTerms: emphasizeMarkedTerms)
        case .consequence:
            return bulletParagraph(runsValue, marker: "→", indent: 14, emphasizeMarkedTerms: emphasizeMarkedTerms)
        case .subpoint:
            return bulletParagraph(runsValue, marker: "◦", indent: 30, emphasizeMarkedTerms: emphasizeMarkedTerms)
        case .explanation:
            return runsParagraph(runsValue, indent: 30, font: bodyItalicFont, emphasizeMarkedTerms: emphasizeMarkedTerms)
        case .note:
            return runsParagraph(runsValue, indent: 14, font: bodyItalicFont, emphasizeMarkedTerms: emphasizeMarkedTerms)
        case .formula:
            let style = paragraphStyle(indent: 14, spacingBefore: 6, spacingAfter: 6)
            style.alignment = .center
            let out = NSMutableAttributedString(string: runsValue.map(\.text).joined() + "\n", attributes: [.font: formulaFont, .paragraphStyle: style])
            return out
        case .subheading:
            return runsParagraph(runsValue, indent: 0, font: subheadingFont, emphasizeMarkedTerms: emphasizeMarkedTerms)
        case .definition:
            // Left bar (like the border of the Word style `Definizione`),
            // normal text.
            return bulletParagraph(runsValue, marker: "\u{258E}", indent: 14, markerColor: definitionBarColor, emphasizeMarkedTerms: emphasizeMarkedTerms)
        case .example:
            return bulletParagraph(runsValue, marker: "\u{258E}", indent: 14, markerColor: exampleBarColor, font: exampleFont, emphasizeMarkedTerms: emphasizeMarkedTerms)
        }
    }

    private static func tableParagraph(columns: [String], rows: [[[RewriteExportRun]]]) -> NSAttributedString {
        guard !columns.isEmpty else { return NSAttributedString() }
        let out = NSMutableAttributedString()
        // No forced bold header any more (direct formatting not tied to the
        // "Emphasise marked terms" option).
        out.append(line(columns.joined(separator: "   ·   "), font: bodyFont, indent: 14, spacingAfter: 2))
        for row in rows {
            let cells = row.map { cell in cell.map(\.text).joined() }
            out.append(line(cells.joined(separator: "   ·   "), font: bodyFont, indent: 14, spacingAfter: 2))
        }
        out.append(NSAttributedString(string: "\n"))
        return out
    }
}
