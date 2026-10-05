import Foundation
import Testing
@testable import LelePdf

/// A manual check with the user's real Word template, kept outside the
/// repository (export of an analyzed document, inspection of `document.xml`
/// and of the style names). NOT a call to Claude (no `LELEPDF_REAL_CLAUDE`
/// gate is needed here: the `.docx` export is deterministic, SPEC); instead
/// it is gated on the EXISTENCE of the user's personal file, exactly as
/// `TestPDFs` does for the test PDFs: if the file is not there (another
/// machine, another session), the test skips cleanly rather than failing.
///
/// The real template (the user's personal Word template) is NEVER copied
/// into the repository nor modified; it is only read and passed to
/// `RewriteDocxTemplateStore` through a temporary EXTRACTION folder outside
/// the repository (`~/Library/Caches/LelePdf/`), the same idea as
/// `WordTemplateSettings` but isolated for this test (never the real
/// Application Support). The export output goes to
/// `~/Library/Caches/LelePdf/verifica-export/`, never into the repository.
///
/// **Known TCC trap**: the test app is ad-hoc signed, so a direct access of
/// its own to `~/Desktop` raises a privacy prompt that nobody can approve
/// and the suite hangs indefinitely (this already happened for the same
/// reason with the test PDFs, fixed by `stage_pdf` in
/// `scripts/test.sh`/`scripts/test-real.sh`). This test therefore reads ONLY
/// the copy already staged in `~/Library/Caches/LelePdf/test-staging/
/// word-template-source.docx` (written by those scripts BEFORE launching
/// `xcodebuild`, by a process other than the test one), never `~/Desktop`
/// directly. If the staged copy is missing (a script other than
/// `scripts/test.sh`/`test-real.sh`, or no template on this machine), the
/// test skips cleanly.
@Suite("Manual check with the user's real Word template (outside the repository)")
struct RealWordTemplateCheck {
    private static let stagedTemplateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/test-staging/word-template-source.docx")

    @Test("export with the real template: no missing style, document.xml has the expected w:pStyle values in order")
    func exportsWithRealTemplateAndListsStyles() throws {
        guard FileManager.default.fileExists(atPath: Self.stagedTemplateURL.path) else {
            print("RealWordTemplateCheck: skipped (staged copy missing: \(Self.stagedTemplateURL.path) — requires scripts/test.sh or scripts/test-real.sh, never a direct access to ~/Desktop from here, see the TCC trap above)")
            return
        }

        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LelePdf", isDirectory: true)
        let extractionDir = cacheRoot.appendingPathComponent("verifica-modello-vero-estratto", isDirectory: true)
        let outputDir = cacheRoot.appendingPathComponent("verifica-export", isDirectory: true)
        try? FileManager.default.removeItem(at: extractionDir)
        try FileManager.default.createDirectory(at: extractionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let archiveData = try Data(contentsOf: Self.stagedTemplateURL)
        let entries = try MinimalZipReader.readEntries(from: archiveData)
        #expect(!entries.isEmpty, "the real template did not unpack into any entry")
        for (path, data) in entries {
            let fileURL = extractionDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL)
        }

        // The test document contains one line for EVERY line type that Claude
        // can produce (`RewriteLineType.knownCases`) plus the four heading
        // levels: if the user renames a style in the template or the app
        // starts using a new one, the test says which role cannot be found.
        // There is no fixed list of styleIds here: the mapping is derived from
        // the styles the template ACTUALLY has.
        var nodes: [RewriteExportNode] = (1 ... 4).map { .heading(text: "Titolo di prova \($0)", level: $0) }
        nodes += RewriteLineType.knownCases.map { type in
            .outlineLine(type, [.init(text: "Riga di prova (\(type.rawValue))"), .init(text: " con un termine segnato", emphasis: true)])
        }
        nodes.append(.outlineLine(.point, [.init(text: "Un ultimo punto, senza dettagli.")]))
        let document = RewriteExportDocument(header: .init(documentTitle: "Test with the real template", sectionLabel: "Whole document", pagesLabel: "p. 1-2"), nodes: nodes)
        let roles: [RewriteDocxStyle] = nodes.map { node in
            switch node {
            case let .heading(_, level): [.heading1, .heading2, .heading3, .heading4][level - 1]
            case let .outlineLine(type, _): RewriteDocxStyle.style(for: type)
            default: .normal
            }
        }

        let templateStyles = try Self.templateParagraphAndCharacterStyles(in: extractionDir)
        #expect(!templateStyles.isEmpty, "no style read from word/styles.xml of the real template")

        for emphasize in [false, true] {
            let result = RewriteDocxExporter.export(for: document, templateDirectory: extractionDir, emphasizeMarkedTerms: emphasize)
            #expect(!result.customTemplateUnreadable, "the real template was not read correctly")
            #expect(result.fallbacksUsed.isEmpty, "real template style not found (renamed or removed?), a built-in one would be used: \(result.fallbacksUsed.map(\.rawValue))")

            if !emphasize { try result.data.write(to: outputDir.appendingPathComponent("prova-modello-vero.docx")) }

            let outputEntries = try MinimalZipReader.readEntries(from: result.data)
            let documentXML = String(data: outputEntries["word/document.xml"] ?? Data(), encoding: .utf8) ?? ""
            let styleSequence = try Self.paragraphStyleSequence(in: documentXML)
            if !emphasize {
                print("RealWordTemplateCheck: w:pStyle sequence seen in document.xml:")
                for style in styleSequence { print("  - \(style)") }
            }

            // One paragraph per node, in node order; every styleId written is
            // ONE OF THE REAL TEMPLATE'S STYLEIDS (exact, case included: Word
            // compares them that way) and matches the expected role by id or
            // by name.
            #expect(styleSequence.count == roles.count, "paragraphs \(styleSequence.count), nodes \(roles.count)")
            for (index, role) in roles.enumerated() where index < styleSequence.count {
                let emitted = styleSequence[index]
                guard let templateStyle = templateStyles.first(where: { $0.id == emitted && !$0.isCharacter }) else {
                    Issue.record("line \(index + 1) (\(role)): styleId \"\(emitted)\" missing from the real template")
                    continue
                }
                let keys = [RewriteDocxStyle.lookupKey(templateStyle.id), RewriteDocxStyle.lookupKey(templateStyle.name)]
                #expect(keys.contains(where: role.lookupKeys.contains), "line \(index + 1): \"\(emitted)\" (name \"\(templateStyle.name)\") is not the style of role \(role)")
            }

            // The character style of the marked terms (option on) is a REAL character style of the template.
            let characterStyles = try Self.characterStyleReferences(in: documentXML)
            if emphasize {
                #expect(!characterStyles.isEmpty)
                for reference in characterStyles { #expect(templateStyles.contains { $0.id == reference && $0.isCharacter }, "w:rStyle \"\(reference)\" is not a character style of the real template") }
            } else {
                #expect(characterStyles.isEmpty)
            }

            // No <w:b/> and no other direct formatting: the "Emphasise marked
            // terms" option is off by default, so even the marked term above
            // must not produce <w:b/>.
            #expect(!documentXML.contains("<w:b/>"))
            #expect(!documentXML.contains("<w:i/>"))
            #expect(!documentXML.contains("w:sz w:val"))
            #expect(!documentXML.contains("<w:pStyle w:val=\"Normal\"/>"))
        }

        try? FileManager.default.removeItem(at: extractionDir)
    }

    // MARK: - Reading the real template (independent of the app code)

    struct TemplateStyle { var id: String; var name: String; var isCharacter: Bool }

    /// Paragraph and character styles from `word/styles.xml` of the unpacked
    /// template, read by the test's own parser (not `RewriteDocxTemplateStore`:
    /// if that one were wrong, the test would not be fooled by the same
    /// error).
    static func templateParagraphAndCharacterStyles(in directory: URL) throws -> [TemplateStyle] {
        let xml = try String(contentsOf: directory.appendingPathComponent("word/styles.xml"), encoding: .utf8)
        let block = try NSRegularExpression(pattern: #"<w:style\s[^>]*>.*?</w:style>"#, options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        return block.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let text = ns.substring(with: match.range)
            func attribute(_ pattern: String) -> String? {
                guard let regex = try? NSRegularExpression(pattern: pattern), let found = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
                return (text as NSString).substring(with: found.range(at: 1))
            }
            guard let id = attribute(#"w:styleId="([^"]+)""#), let type = attribute(#"w:type="([^"]+)""#), type == "paragraph" || type == "character" else { return nil }
            return TemplateStyle(id: id, name: attribute(#"<w:name w:val="([^"]*)""#) ?? id, isCharacter: type == "character")
        }
    }

    static func paragraphStyleSequence(in documentXML: String) throws -> [String] {
        try matches(#"<w:pStyle w:val="([^"]+)"/>"#, in: documentXML)
    }

    static func characterStyleReferences(in documentXML: String) throws -> [String] {
        try matches(#"<w:rStyle w:val="([^"]+)"/>"#, in: documentXML)
    }

    private static func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Re-exports the user's REAL Ockham document with the real template, and
    /// reports (on the console, via `print`) `w:pStyle` per paragraph plus a
    /// count of direct formatting, to be compared with the previously
    /// reported bad export (295 `<w:b/>`, `Heading4` for every card,
    /// generated `Title`/`Subtitle`, `Normal` lines).
    ///
    /// Reads the user's REAL `documento.json`/`analisi.json` ONLY from the
    /// copy staged outside the repository (`scripts/test.sh`,
    /// "ockham-real-analysis"), never `~/Documents/LelePdf` directly from
    /// inside the test process: same TCC trap as `RealWordTemplateCheck`
    /// above. A direct access to `~/Documents` from an ad-hoc signed app
    /// raises a privacy prompt that nobody can approve and hangs the suite
    /// indefinitely. If the staged copy is missing (a script other than
    /// `scripts/test.sh`, or the user's real folder does not exist on this
    /// machine), the test skips cleanly.
    @Test("real check: re-exports the user's real Ockham document with their real template, reports pStyle and direct formatting")
    @MainActor
    func reexportsRealOckhamDocumentAndReportsStyles() throws {
        guard FileManager.default.fileExists(atPath: Self.stagedTemplateURL.path) else {
            print("RealWordTemplateCheck (Ockham): skipped (staged template copy missing)")
            return
        }
        let ockhamStagedFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/test-staging/ockham-real-analysis", isDirectory: true)
        let documentURL = ockhamStagedFolder.appendingPathComponent("documento.json")
        let analysisURL = ockhamStagedFolder.appendingPathComponent("analisi.json")
        guard FileManager.default.fileExists(atPath: documentURL.path), FileManager.default.fileExists(atPath: analysisURL.path) else {
            print("RealWordTemplateCheck (Ockham): skipped (staged copy missing: \(ockhamStagedFolder.path) — requires scripts/test.sh, never a direct access to ~/Documents/LelePdf from here)")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let documentRecord = try decoder.decode(DocumentRecord.self, from: Data(contentsOf: documentURL))
        let analysisRecord = try decoder.decode(AnalysisRecord.self, from: Data(contentsOf: analysisURL))

        let exportDocument = RewriteExportModel.build(document: documentRecord, analysis: analysisRecord, scope: .wholeDocument, currentBlockId: nil)

        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LelePdf", isDirectory: true)
        let extractionDir = cacheRoot.appendingPathComponent("verifica-modello-vero-estratto-ockham", isDirectory: true)
        let outputDir = cacheRoot.appendingPathComponent("verifica-export", isDirectory: true)
        try? FileManager.default.removeItem(at: extractionDir)
        try FileManager.default.createDirectory(at: extractionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let archiveData = try Data(contentsOf: Self.stagedTemplateURL)
        for (path, data) in try MinimalZipReader.readEntries(from: archiveData) {
            let fileURL = extractionDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL)
        }

        let result = RewriteDocxExporter.export(for: exportDocument, templateDirectory: extractionDir)
        #expect(!result.customTemplateUnreadable)
        // No built-in style in place of one from the real template.
        #expect(result.fallbacksUsed.isEmpty, "real template style not found: \(result.fallbacksUsed.map(\.rawValue))")
        try result.data.write(to: outputDir.appendingPathComponent("ockham-f18.docx"))
        let templateStyles = try Self.templateParagraphAndCharacterStyles(in: extractionDir)

        let entries = try MinimalZipReader.readEntries(from: result.data)
        let documentXML = String(data: entries["word/document.xml"] ?? Data(), encoding: .utf8) ?? ""

        let styleCounts = try styleCounts(in: documentXML)
        for style in styleCounts.keys {
            #expect(templateStyles.contains { $0.id == style && !$0.isCharacter }, "w:pStyle \"\(style)\" is not a paragraph style of the real template")
        }
        let directBold = documentXML.components(separatedBy: "<w:b/>").count - 1
        let directItalic = documentXML.components(separatedBy: "<w:i/>").count - 1
        let directSize = documentXML.components(separatedBy: "w:sz w:val").count - 1
        let directColor = documentXML.components(separatedBy: "w:color w:val").count - 1
        let pageSuffixOccurrences = documentXML.components(separatedBy: "· p.").count - 1

        print("RealWordTemplateCheck (Ockham): re-exported \(styleCounts.values.reduce(0, +)) paragraphs with these w:pStyle values:")
        for (style, count) in styleCounts.sorted(by: { $0.key < $1.key }) { print("  - \(style): \(count)") }
        print("RealWordTemplateCheck (Ockham): direct formatting -- <w:b/>: \(directBold), <w:i/>: \(directItalic), w:sz: \(directSize), w:color: \(directColor), '· p.' in the text: \(pageSuffixOccurrences)")

        // Direct comparison with the bad export described above: zero direct
        // formatting by default (295 <w:b/> in the old file), no Normal
        // (the "The block traces..." lines in the old file), no "· p." in the
        // text (card pages in the old file).
        #expect(directBold == 0)
        #expect(directItalic == 0)
        #expect(directSize == 0)
        #expect(directColor == 0)
        #expect(pageSuffixOccurrences == 0)
        #expect(styleCounts["Normal"] == nil, "no paragraph must end up in Normal")
        #expect(styleCounts["Title"] == nil)
        #expect(styleCounts["Subtitle"] == nil)

        try? FileManager.default.removeItem(at: extractionDir)
    }

    private func styleCounts(in documentXML: String) throws -> [String: Int] {
        let pattern = try NSRegularExpression(pattern: #"<w:pStyle w:val="([^"]+)"/>"#)
        let ns = documentXML as NSString
        let styles = pattern.matches(in: documentXML, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        return Dictionary(styles.map { ($0, 1) }, uniquingKeysWith: +)
    }
}
