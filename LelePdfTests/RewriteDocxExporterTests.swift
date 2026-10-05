import Foundation
import Testing
@testable import LelePdf

/// "Word (.docx)" (SPEC §8.2): the hand-built ZIP package
/// (`MinimalZipWriter`) must be a real ZIP (verified with `/usr/bin/unzip`,
/// not with our own writer) and `word/document.xml` must have ONLY the
/// expected styles, NEVER direct paragraph or run formatting (only the
/// template's `w:pStyle`, zero direct `<w:b/>`/`<w:i/>`/`<w:sz>`/`<w:color>`,
/// no 'Normal'). Here: ONLY the built-in template (no chosen template
/// folder); the chosen template and its patching are covered in
/// `RewriteDocxTemplateStoreTests.swift`.
@Suite("RewriteDocxExporter")
struct RewriteDocxExporterTests {
    private func sampleDocument() -> RewriteExportDocument {
        RewriteExportDocument(
            header: .init(documentTitle: "Documento & prova <Word>", sectionLabel: "Tutto il documento", pagesLabel: "p. 1-2"),
            nodes: [
                .heading(text: "Capitolo 1", level: 1),
                .heading(text: "Sotto-sezione a T4 di prova", level: 4),
                .outlineLine(.point, [.init(text: "Punto con "), .init(text: "termine", emphasis: true)]),
                .outlineLine(.subpoint, [.init(text: "Sottopunto uno")]),
                .outlineLine(.consequence, [.init(text: "Conseguenza del punto")]),
                .outlineLine(.note, [.init(text: "Una nota a parte")]),
                .outlineLine(.formula, [.init(text: "E = mc^2")]),
                .outlineLine(.explanation, [.init(text: "Spiegazione del punto")]),
                .outlineLine(.subheading, [.init(text: "Titoletto raro")]),
                .steps([[.init(text: "Primo passo")], [.init(text: "Secondo passo")]]),
                .table(columns: ["A", "B"], rows: [[[.init(text: "1")], [.init(text: "2")]]]),
                .exhibit("Figura 1, p. 3"),
            ]
        )
    }

    private func writeTemp(_ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfDocxExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("export.docx")
        try data.write(to: file)
        return file
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        try process.run()
        let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: outputData, encoding: .utf8) ?? "")
    }

    private func extract(_ file: URL, path: String) throws -> String {
        let (status, output) = try run("/usr/bin/unzip", ["-p", file.path, path])
        #expect(status == 0, "unzip -p \(path) failed")
        return output
    }

    @Test("the package is a real ZIP: /usr/bin/unzip -t (CRC integrity) and -l (part listing) confirm it")
    func packageIsAValidZipArchive() throws {
        let file = try writeTemp(RewriteDocxExporter.data(for: sampleDocument()))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let (testStatus, testOutput) = try run("/usr/bin/unzip", ["-t", file.path])
        #expect(testStatus == 0, "archive corrupted according to unzip -t: \(testOutput)")

        let (listStatus, listOutput) = try run("/usr/bin/unzip", ["-l", file.path])
        #expect(listStatus == 0)
        for expectedPart in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml", "word/_rels/document.xml.rels"] {
            #expect(listOutput.contains(expectedPart), "OOXML part missing from the package: \(expectedPart)")
        }
    }

    @Test("document.xml is well-formed XML, with a w:pStyle for every line type, in the expected order, with no generated heading, no direct formatting, no Normal, and no w:b even on a marked term (off by default)")
    func documentXMLStructure() throws {
        let file = try writeTemp(RewriteDocxExporter.data(for: sampleDocument()))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let xml = try extract(file, path: "word/document.xml")

        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse(), "document.xml not well-formed: \(parser.parserError?.localizedDescription ?? "?")")

        // No generated heading (no Title/Subtitle, no document title/section/pages).
        #expect(!xml.contains("<w:pStyle w:val=\"Title\"/>"))
        #expect(!xml.contains("<w:pStyle w:val=\"Subtitle\"/>"))
        #expect(!xml.contains("Documento &amp; prova"), "the heading (document title) must no longer appear in the body")

        // By default NO direct bold, not even on a marked term.
        #expect(!xml.contains("<w:b/>"), "no direct <w:b/> by default, not even on a marked term")
        #expect(!xml.contains("<w:i/>"))
        #expect(!xml.contains("w:sz w:val"))
        #expect(!xml.contains("w:color w:val"))

        // Never "Normal".
        #expect(!xml.contains("<w:pStyle w:val=\"Normal\"/>"), "no paragraph must ever end up in Normal")

        #expect(xml.contains("<w:pStyle w:val=\"Heading1\"/>"))
        // Test level-4 heading: the built-in template has Heading4.
        #expect(xml.contains("<w:pStyle w:val=\"Heading4\"/>"))

        for expectedStyle in ["Puntoelenco", "Sub-puntoelenco", "Conseguenza", "Nota", "Formula", "Spiegazionebullet", "GrassoTitoli", "Nota"] {
            #expect(xml.contains("<w:pStyle w:val=\"\(expectedStyle)\"/>"), "missing styleId: \(expectedStyle)")
        }
        #expect(xml.contains("<w:pStyle w:val=\"ListParagraph\"/>"), "steps/table use ListParagraph, never Normal")

        // A single w:pStyle per line, EXACTLY the expected style map, with no
        // direct numPr/ind/color (the numbering lives in the style itself:
        // "no direct formatting").
        let outlineParagraphs = ["Punto con ", "Sottopunto uno", "Conseguenza del punto", "Una nota a parte", "E = mc", "Spiegazione del punto", "Titoletto raro"]
        for marker in outlineParagraphs {
            let range = try #require(xml.range(of: marker))
            let paragraphStart = xml.range(of: "<w:p>", options: .backwards, range: xml.startIndex ..< range.lowerBound)?.lowerBound ?? xml.startIndex
            let paragraphEnd = xml.range(of: "</w:p>", range: range.upperBound ..< xml.endIndex)?.upperBound ?? xml.endIndex
            let paragraphXML = xml[paragraphStart ..< paragraphEnd]
            #expect(!paragraphXML.contains("w:numPr"), "direct formatting (numPr) on the paragraph of \"\(marker)\"")
            #expect(!paragraphXML.contains("w:ind "), "direct formatting (ind) on the paragraph of \"\(marker)\"")
        }

        // `steps` (a kind kept for analyses produced by older versions): the
        // only one left with an explicit w:numPr, a dedicated list (reserved
        // numId).
        #expect(xml.contains(#"<w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="9003"/></w:numPr>"#))

        // Order: the sub-point appears after its main point, the consequence
        // after the sub-point.
        let mainRange = try #require(xml.range(of: "Punto con "))
        let subRange = try #require(xml.range(of: "Sottopunto uno"))
        let consequenceRange = try #require(xml.range(of: "Conseguenza del punto"))
        #expect(mainRange.lowerBound < subRange.lowerBound)
        #expect(subRange.lowerBound < consequenceRange.lowerBound)
    }

    @Test("definition and example take the Definizione and Example styles, with no direct formatting, in the built-in template too")
    func definitionAndExampleUseTheirOwnStyles() throws {
        let document = RewriteExportDocument(
            header: .init(documentTitle: "Prova", sectionLabel: "Tutto il documento", pagesLabel: "p. 1"),
            nodes: [
                .outlineLine(.point, [.init(text: "Un punto")]),
                .outlineLine(.definition, [.init(text: "Moat: a durable advantage")]),
                .outlineLine(.example, [.init(text: "For instance, a patent")]),
            ]
        )
        let xml = RewriteDocxExporter.documentXML(for: document)
        let styles = xml.components(separatedBy: "<w:pStyle w:val=\"").dropFirst().map { $0.prefix { $0 != "\"" } }.map(String.init)
        #expect(styles == ["Puntoelenco", "Definizione", "Example"])
        #expect(!xml.contains("<w:b/>") && !xml.contains("<w:i/>") && !xml.contains("w:sz w:val"))
        let stylesXML = RewriteDocxDefaultTemplate.defaultStylesXML
        #expect(stylesXML.contains("w:styleId=\"Definizione\"") && stylesXML.contains("w:styleId=\"Example\"") && stylesXML.contains("w:styleId=\"GrassoTitoli\""))
    }

    @Test("'Emphasise marked terms' on: a marked term references the IntenseEmphasis character style, never a direct <w:b/>")
    func emphasizeMarkedTermsUsesCharacterStyleNotDirectBold() throws {
        let data = RewriteDocxExporter.data(for: sampleDocument(), emphasizeMarkedTerms: true)
        let file = try writeTemp(data)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let xml = try extract(file, path: "word/document.xml")

        #expect(!xml.contains("<w:b/>"), "never a direct <w:b/>, not even with the option on")
        #expect(xml.contains("<w:rStyle w:val=\"IntenseEmphasis\"/>"), "the marked term must reference the character style")

        let stylesXML = try extract(file, path: "word/styles.xml")
        #expect(stylesXML.contains("w:styleId=\"IntenseEmphasis\""), "the character style must exist in the package")
    }

    @Test("numbering.xml defines the reserved lists for point/sub-point, consequence and steps")
    func numberingDefinitions() throws {
        let file = try writeTemp(RewriteDocxExporter.data(for: sampleDocument()))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let xml = try extract(file, path: "word/numbering.xml")

        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse())

        #expect(xml.contains(#"w:numFmt w:val="bullet""#))
        #expect(xml.contains(#"w:numFmt w:val="decimal""#))
        #expect(xml.contains(#"<w:num w:numId="9001">"#)) // point/sub-point
        #expect(xml.contains(#"<w:num w:numId="9002">"#)) // consequence
        #expect(xml.contains(#"<w:num w:numId="9003">"#)) // steps (older analyses)
    }

    @Test("a document with no nodes still produces a valid .docx, with no heading")
    func emptyBodyStillProducesValidPackage() throws {
        let empty = RewriteExportDocument(header: .init(documentTitle: "Solo intestazione", sectionLabel: "Sezione corrente", pagesLabel: "p. 1"), nodes: [])
        let file = try writeTemp(RewriteDocxExporter.data(for: empty))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let (status, _) = try run("/usr/bin/unzip", ["-t", file.path])
        #expect(status == 0)
        let xml = try extract(file, path: "word/document.xml")
        #expect(!xml.contains("Solo intestazione"), "no generated heading, not even for an empty document")
    }
}
