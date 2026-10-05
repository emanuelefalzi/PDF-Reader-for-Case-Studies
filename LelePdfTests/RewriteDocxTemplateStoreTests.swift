import Foundation
import Testing
@testable import LelePdf

/// "Chosen template" + "missing style: nearest built-in style, reported": a
/// SYNTHETIC template (never the user's real template, which is read only
/// outside the tests) with THE SAME styleIds but only a subset of them, to
/// verify the deterministic patching.
@Suite("RewriteDocxTemplateStore: chosen template and patching")
struct RewriteDocxTemplateStoreTests {
    /// styleIds present in the synthetic template: three headings, point and
    /// consequence. Sub-puntoelenco/Nota/Formula/Spiegazionebullet/
    /// GrassoTitoli/Definizione/Example/Heading4 are deliberately MISSING (to
    /// verify both the reported patching and Heading4's own rule).
    private static let syntheticStylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:customStyle="1" w:styleId="Puntoelenco"><w:name w:val="Punto elenco"/><w:basedOn w:val="Normal"/><w:pPr><w:numPr><w:numId w:val="501"/></w:numPr></w:pPr></w:style>
    <w:style w:type="paragraph" w:customStyle="1" w:styleId="Conseguenza"><w:name w:val="Conseguenza"/><w:basedOn w:val="Normal"/><w:pPr><w:numPr><w:numId w:val="502"/></w:numPr></w:pPr></w:style>
    </w:styles>
    """

    private static let syntheticNumberingXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:abstractNum w:abstractNumId="50"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/></w:lvl></w:abstractNum>
    <w:abstractNum w:abstractNumId="51"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="→"/></w:lvl></w:abstractNum>
    <w:num w:numId="501"><w:abstractNumId w:val="50"/></w:num>
    <w:num w:numId="502"><w:abstractNumId w:val="51"/></w:num>
    </w:numbering>
    """

    /// Synthetic ZIP archive ("store" method, `MinimalZipWriter`) with the
    /// minimal skeleton of a `.docx`, read exactly as
    /// `WordTemplateSettings.chooseTemplate` would read a real file.
    private func syntheticTemplateArchive() -> Data {
        MinimalZipWriter.makeArchive(entries: [
            .init(path: "[Content_Types].xml", data: Data(RewriteDocxTemplates.contentTypesXML.utf8)),
            .init(path: "_rels/.rels", data: Data(RewriteDocxTemplates.packageRelsXML.utf8)),
            .init(path: "word/_rels/document.xml.rels", data: Data(RewriteDocxTemplates.documentRelsXML.utf8)),
            .init(path: "word/document.xml", data: Data("<w:document><w:body>documento originale, mai riusato</w:body></w:document>".utf8)),
            .init(path: "word/styles.xml", data: Data(Self.syntheticStylesXML.utf8)),
            .init(path: "word/numbering.xml", data: Data(Self.syntheticNumberingXML.utf8)),
            .init(path: "word/fontTable.xml", data: Data("<w:fonts/>".utf8)),
        ])
    }

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfWordTemplateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("MinimalZipReader rereads a store archive: all entries, text intact")
    func zipReaderReadsStoreArchive() throws {
        let archive = syntheticTemplateArchive()
        let entries = try MinimalZipReader.readEntries(from: archive)
        #expect(entries["word/styles.xml"].flatMap { String(data: $0, encoding: .utf8) } == Self.syntheticStylesXML)
        #expect(entries["word/numbering.xml"] != nil)
        #expect(entries["[Content_Types].xml"] != nil)
        #expect(entries.count == 7)
    }

    /// Simulates `WordTemplateSettings.chooseTemplate` without going through
    /// `NSOpenPanel`/the real Application Support: writes the entries it
    /// reads directly into the test folder.
    private func extractSynthetic(into directory: URL) throws {
        let entries = try MinimalZipReader.readEntries(from: syntheticTemplateArchive())
        for (path, data) in entries {
            let fileURL = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL)
        }
    }

    @Test("incomplete chosen template: present styles stay unchanged, missing ones take the built-in style and are reported")
    func resolveCustomPatchesMissingStyles() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try extractSynthetic(into: dir)

        let resolved = RewriteDocxTemplateStore.resolve(customTemplateDirectory: dir)

        #expect(!resolved.customTemplateUnreadable)
        #expect(resolved.availableStyleIds == ["Normal", "Heading1", "Heading2", "Heading3", "Puntoelenco", "Conseguenza"])
        #expect(Set(resolved.fallbacksUsed.map(\.rawValue)) == ["Sub-puntoelenco", "Nota", "Formula", "Spiegazionebullet", "GrassoTitoli", "Definizione", "Example"])
        // Heading4 is never a reported patch (its own rule).
        #expect(!resolved.fallbacksUsed.contains(.heading4))

        // The original `word/document.xml` does not survive: the exporter writes it.
        #expect(resolved.entries["word/document.xml"] == nil)
        // A file outside the style table (fontTable) stays byte for byte the chosen template's.
        #expect(resolved.entries["word/fontTable.xml"] == Data("<w:fonts/>".utf8))

        let patchedStyles = String(data: resolved.entries["word/styles.xml"] ?? Data(), encoding: .utf8) ?? ""
        for missing in ["Sub-puntoelenco", "Nota", "Formula", "Spiegazionebullet", "GrassoTitoli", "Definizione", "Example"] {
            #expect(patchedStyles.contains("w:styleId=\"\(missing)\""), "built-in styleId not injected: \(missing)")
        }
        // Styles ALREADY present stay the chosen template's (synthetic numId 501/502), not replaced by the patch.
        #expect(patchedStyles.contains(#"w:numId w:val="501""#))
        #expect(patchedStyles.contains(#"w:numId w:val="502""#))

        let patchedNumbering = String(data: resolved.entries["word/numbering.xml"] ?? Data(), encoding: .utf8) ?? ""
        #expect(patchedNumbering.contains(#"w:numId="9001""#)) // built-in sub-point injected
        #expect(patchedNumbering.contains(#"w:numId="9003""#)) // steps, always included
    }

    @Test("the real export with this incomplete template produces styleIds from the expected map; a level-4 heading falls back to Heading3 (Heading4 absent)")
    @MainActor
    func exportUsesResolvedTemplate() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try extractSynthetic(into: dir)

        let document = RewriteExportDocument(
            header: .init(documentTitle: "Prova", sectionLabel: "Tutto il documento", pagesLabel: "p. 1"),
            nodes: [
                .heading(text: "T4 di prova", level: 4),
                .outlineLine(.point, [.init(text: "Punto")]),
                .outlineLine(.subpoint, [.init(text: "Sottopunto")]),
                .outlineLine(.note, [.init(text: "Nota")]),
            ]
        )
        let result = RewriteDocxExporter.export(for: document, templateDirectory: dir)
        #expect(!result.customTemplateUnreadable)
        #expect(Set(result.fallbacksUsed.map(\.rawValue)).isSuperset(of: ["Sub-puntoelenco", "Nota"]))

        let entries = try MinimalZipReader.readEntries(from: result.data)
        let documentXML = String(data: entries["word/document.xml"] ?? Data(), encoding: .utf8) ?? ""
        #expect(documentXML.contains("<w:pStyle w:val=\"Heading3\"/>"), "a level-4 heading without Heading4 in the chosen template must fall back to Heading3")
        #expect(!documentXML.contains("Heading4"))
        #expect(documentXML.contains("<w:pStyle w:val=\"Puntoelenco\"/>"))
        #expect(documentXML.contains("<w:pStyle w:val=\"Sub-puntoelenco\"/>"))
        #expect(documentXML.contains("<w:pStyle w:val=\"Nota\"/>"))
    }

    @Test("chosen template folder missing/empty: falls back to the built-in template, reported as unreadable")
    func resolveFallsBackWhenDirectoryUnreadable() throws {
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdf-non-esiste-\(UUID().uuidString)")
        let resolved = RewriteDocxTemplateStore.resolve(customTemplateDirectory: missingDir)
        #expect(resolved.customTemplateUnreadable)
        #expect(resolved.fallbacksUsed.isEmpty) // the built-in template never needs a patch
        #expect(resolved.availableStyleIds.contains("Puntoelenco"))
    }

    @Test("no chosen template (nil): built-in template, not reported as unreadable")
    func resolveDefaultWithoutChoice() {
        let resolved = RewriteDocxTemplateStore.resolve(customTemplateDirectory: nil)
        #expect(!resolved.customTemplateUnreadable)
        #expect(resolved.fallbacksUsed.isEmpty)
        #expect(resolved.availableStyleIds.count == RewriteDocxStyle.allCases.count)
    }

    // MARK: - Lookup by id OR by name, ignoring case/spaces/hyphens

    /// Synthetic template where every style has an id and a name WRITTEN DIFFERENTLY from the built-in ones.
    private func resolveStyles(_ styles: [(id: String, name: String, type: String)]) throws -> RewriteDocxTemplateStore.Resolved {
        let body = styles.map { #"<w:style w:type="\#($0.type)" w:styleId="\#($0.id)"><w:name w:val="\#($0.name)"/></w:style>"# }.joined()
        let xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"# + body + "</w:styles>"
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("word"), withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: dir.appendingPathComponent("word/styles.xml"))
        return RewriteDocxTemplateStore.resolve(customTemplateDirectory: dir)
    }

    @Test("grassotitoli, GrassoTitoli and 'Grasso Titoli' are the same style, whatever the id")
    func subheadingFoundByIdOrNameCaseInsensitive() throws {
        for (id, name) in [("GrassoTitoli", "Grasso Titoli"), ("grassotitoli", "grasso titoli"), ("Stile7", "Grasso titoli"), ("Grasso-Titoli", "x")] {
            let resolved = try resolveStyles([(id, name, "paragraph")])
            #expect(!resolved.fallbacksUsed.contains(.subheading), "\(id)/\(name): must not have been a patch")
            #expect(resolved.styleMap.id(for: .subheading) == id, "\(id)/\(name): document.xml must write the template's REAL styleId")
        }
    }

    @Test("every mapped style is found by name under another id (Sub-punto elenco, Punto elenco, Definizione, Example, heading 1)")
    func everyMappedStyleFoundByName() throws {
        let resolved = try resolveStyles([
            ("A1", "Punto Elenco", "paragraph"), ("A2", "sub-punto elenco", "paragraph"), ("A3", "SPIEGAZIONE BULLET", "paragraph"),
            ("A4", "nota", "paragraph"), ("A5", "formula", "paragraph"), ("A6", "Conseguenza", "paragraph"),
            ("A7", "definizione", "paragraph"), ("A8", "example", "paragraph"), ("A9", "Heading 1", "paragraph"),
            ("B1", "heading 2", "paragraph"), ("B2", "Heading 3", "paragraph"), ("B3", "Heading 4", "paragraph"),
        ])
        #expect(resolved.styleMap.id(for: .point) == "A1")
        #expect(resolved.styleMap.id(for: .subpoint) == "A2")
        #expect(resolved.styleMap.id(for: .explanation) == "A3")
        #expect(resolved.styleMap.id(for: .definition) == "A7")
        #expect(resolved.styleMap.id(for: .example) == "A8")
        #expect(resolved.styleMap.id(for: .heading1) == "A9")
        #expect(resolved.styleMap.has(.heading4))
        // The only patches are the styles that are really missing: GrassoTitoli.
        #expect(resolved.fallbacksUsed == [.subheading])
    }

    @Test("a PARAGRAPH style 'Grassetto' is never the character style of marked terms")
    func paragraphStyleIsNeverTheCharacterStyle() throws {
        let resolved = try resolveStyles([("Grassetto", "Grassetto", "paragraph"), ("Enfasi", "Intense Emphasis", "character")])
        #expect(resolved.styleMap.id(for: .markedTerm) == "Enfasi", "the character style is found by name among character styles, not paragraph ones")
        #expect(resolved.styleMap.id(for: .normal) == "Normal", "missing styles that are not reported take the built-in id")
    }

    @Test("the export writes the template's real (renamed) styleId, not the built-in one")
    func exportWritesTheTemplatesOwnStyleId() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("word"), withIntermediateDirectories: true)
        let xml = #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:type="paragraph" w:styleId="MioTitoletto"><w:name w:val="grasso titoli"/></w:style><w:style w:type="paragraph" w:styleId="Def"><w:name w:val="Definizione"/></w:style></w:styles>"#
        try Data(xml.utf8).write(to: dir.appendingPathComponent("word/styles.xml"))
        let document = RewriteExportDocument(
            header: .init(documentTitle: "P", sectionLabel: "S", pagesLabel: "p. 1"),
            nodes: [.outlineLine(.subheading, [.init(text: "T")]), .outlineLine(.definition, [.init(text: "D")]), .outlineLine(.example, [.init(text: "E")])]
        )
        let result = RewriteDocxExporter.export(for: document, templateDirectory: dir)
        let entries = try MinimalZipReader.readEntries(from: result.data)
        let documentXML = String(data: entries["word/document.xml"] ?? Data(), encoding: .utf8) ?? ""
        #expect(documentXML.contains(#"<w:pStyle w:val="MioTitoletto"/>"#))
        #expect(documentXML.contains(#"<w:pStyle w:val="Def"/>"#))
        #expect(documentXML.contains(#"<w:pStyle w:val="Example"/>"#), "Example is missing from the template: built-in style injected and reported")
        #expect(result.fallbacksUsed.contains(.example) && !result.fallbacksUsed.contains(.subheading) && !result.fallbacksUsed.contains(.definition))
    }
}
