import AppKit
import Testing
@testable import LelePdf

/// "Copy with formatting" (SPEC §8.1, "same structure in all three
/// formats"): the content types on the clipboard and the structure of the
/// rich text. A PRIVATE `NSPasteboard` (never `.general`, never the user's
/// real clipboard; `RewriteCopyExporter.write` takes the pasteboard as a
/// parameter precisely for this).
@MainActor
@Suite("RewriteCopyExporter")
struct RewriteCopyExporterTests {
    private func sampleDocument() -> RewriteExportDocument {
        RewriteExportDocument(
            header: .init(documentTitle: "Documento di prova", sectionLabel: "Tutto il documento", pagesLabel: "p. 1-2"),
            nodes: [
                .heading(text: "Capitolo 1", level: 1),
                .outlineLine(.point, [.init(text: "Punto con "), .init(text: "termine", emphasis: true)]),
                .outlineLine(.subpoint, [.init(text: "Sottopunto uno")]),
                .outlineLine(.subpoint, [.init(text: "Sottopunto due")]),
                .outlineLine(.point, [.init(text: "Punto senza sottopunti")]),
                .outlineLine(.explanation, [.init(text: "una definizione.")]),
            ]
        )
    }

    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("it.lelepdf.tests.export-\(UUID().uuidString)"))
    }

    @Test("the clipboard has both the RTF type and the plain-text fallback")
    func pasteboardHasBothFlavors() {
        let pasteboard = privatePasteboard()
        RewriteCopyExporter.write(sampleDocument(), to: pasteboard)
        let types = pasteboard.types ?? []
        #expect(types.contains(.rtf))
        #expect(types.contains(.string))
    }

    @Test("the plain-text fallback uses the Markdown syntax of SPEC §8, with no generated heading and no bold on the marked term (option off by default)")
    func plainTextFallbackIsMarkdown() {
        let pasteboard = privatePasteboard()
        RewriteCopyExporter.write(sampleDocument(), to: pasteboard)
        let plain = pasteboard.string(forType: .string) ?? ""
        #expect(!plain.contains("Documento di prova"), "no generated heading")
        #expect(plain.contains("## Capitolo 1"))
        #expect(plain.contains("- Punto con termine"), "marked term not bold by default")
        #expect(!plain.contains("**termine**"))
        #expect(plain.contains("  - Sottopunto uno"))
        #expect(plain.contains("  - Sottopunto due"))
        #expect(plain.contains("- Punto senza sottopunti"))
    }

    @Test("'Emphasise marked terms' on: the marked term is bold again in the plain-text fallback")
    func plainTextEmphasizesWhenOptionOn() {
        let pasteboard = privatePasteboard()
        RewriteCopyExporter.write(sampleDocument(), to: pasteboard, emphasizeMarkedTerms: true)
        let plain = pasteboard.string(forType: .string) ?? ""
        #expect(plain.contains("- Punto con **termine**"))
    }

    @Test("the RTF reloads as an NSAttributedString with points/sub-points indented differently, the term NOT bold by default")
    func rtfRoundTripsWithStructure() throws {
        let attributed = RewriteExportAttributedString.build(sampleDocument())
        let rtf = try #require(RewriteCopyExporter.rtfData(for: attributed))

        var attributes: NSDictionary?
        let reloaded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: &attributes)
        let text = reloaded.string

        #expect(text.contains("•\tPunto con termine"))
        #expect(text.contains("◦\tSottopunto uno"))
        #expect(text.contains("◦\tSottopunto due"))

        // The sub-point's indent (`headIndent`) must be greater than the main
        // point's (SPEC §8.4, "different indentation"), verified here on the
        // real RTF file, not on the model.
        let mainRange = (text as NSString).range(of: "•\tPunto con termine")
        let subRange = (text as NSString).range(of: "◦\tSottopunto uno")
        let mainStyle = reloaded.attribute(.paragraphStyle, at: mainRange.location, effectiveRange: nil) as? NSParagraphStyle
        let subStyle = reloaded.attribute(.paragraphStyle, at: subRange.location, effectiveRange: nil) as? NSParagraphStyle
        let mainIndent = try #require(mainStyle?.headIndent)
        let subIndent = try #require(subStyle?.headIndent)
        #expect(subIndent > mainIndent)

        // "termine" (a mark) is NOT bold by default.
        let termineRange = (text as NSString).range(of: "termine")
        let termineFont = reloaded.attribute(.font, at: termineRange.location, effectiveRange: nil) as? NSFont
        #expect(termineFont?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }

    @Test("'Emphasise marked terms' on: the marked term is bold again in the RTF")
    func rtfEmphasizesWhenOptionOn() throws {
        let attributed = RewriteExportAttributedString.build(sampleDocument(), emphasizeMarkedTerms: true)
        let rtf = try #require(RewriteCopyExporter.rtfData(for: attributed))
        let reloaded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let text = reloaded.string
        let termineRange = (text as NSString).range(of: "termine")
        let termineFont = reloaded.attribute(.font, at: termineRange.location, effectiveRange: nil) as? NSFont
        #expect(termineFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }
}
