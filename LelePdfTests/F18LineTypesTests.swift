import AppKit
import Foundation
import Testing
@testable import LelePdf

/// The two newer line types, `definition` (Word style `Definizione`) and
/// `example` (`Example`), read/written/exported like any other type, and an
/// old `kind == .definition` that now goes into the `Definizione` style.
@Suite("Line types · definition and example")
struct F18LineTypesTests {
    @Test("decoding and encoding: the two new types are real cases, not .other; an old analisi.json stays readable")
    func codableRoundTrip() throws {
        for (raw, expected) in [("definition", RewriteLineType.definition), ("example", .example)] {
            let line = try JSONDecoder().decode(RewriteLine.self, from: Data(#"{"type":"\#(raw)","text":"t"}"#.utf8))
            #expect(line.type == expected)
            #expect(try JSONDecoder().decode(RewriteLine.self, from: JSONEncoder().encode(line)).type == expected)
        }
        // An analisi.json written before these types existed (only the seven
        // original types) is unchanged.
        let old = try JSONDecoder().decode(RewriteItem.self, from: Data(#"{"kind":"outline","lines":[{"type":"point","text":"a"},{"type":"subheading","text":"b"}]}"#.utf8))
        #expect(old.lines?.map(\.type) == [.point, .subheading])
    }

    @Test("knownCases lists every type the style template must be able to export, and each has a Word style")
    func everyKnownCaseHasAStyle() {
        #expect(Set(RewriteLineType.knownCases.map(\.rawValue)).count == RewriteLineType.knownCases.count)
        #expect(RewriteLineType.knownCases.contains(.definition) && RewriteLineType.knownCases.contains(.example))
        #expect(RewriteDocxStyle.style(for: .definition) == .definition)
        #expect(RewriteDocxStyle.style(for: .example) == .example)
        #expect(!RewriteLineType.definition.isNested && !RewriteLineType.example.isNested)
    }

    @Test("the JSON schema admits definition and example, and the contract and the prompt name them")
    func schemaAndPromptsMentionNewTypes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LelePdf/Resources")
        let schema = try String(contentsOf: root.appendingPathComponent("Schemas/analysis.schema.json"), encoding: .utf8)
        #expect(schema.contains(#""enum": ["point", "subpoint", "explanation", "note", "formula", "consequence", "subheading", "definition", "example"]"#))
        let json = try #require(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        #expect(json["type"] as? String == "object")
        for file in ["Prompts/analysis.md", "Prompts/analysis-contract.md", "Prompts/rewrite-block.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(text.contains("`definition`") || text.contains("definition"), "\(file) does not name definition")
            #expect(text.contains("`example`") || text.contains("example"), "\(file) does not name example")
        }
    }

    @Test("the normalizer keeps definition and example at top level: a sub-point after them stays nested")
    func normalizerKeepsThemTopLevel() {
        let item = RewriteItem(kind: .outline, lines: [
            RewriteLine(type: .definition, text: "Moat: a durable edge"),
            RewriteLine(type: .subpoint, text: "dettaglio"),
            RewriteLine(type: .example, text: "For instance, a patent"),
        ])
        #expect(OutlineLinesNormalizer.align(item).lines?.map(\.type) == [.definition, .subpoint, .example])
    }

    @Test("Edit text: the 'def: ' and 'ex: ' prefixes round-trip, markers included")
    func editTextRoundTrip() {
        let items = [RewriteItem(kind: .outline, lines: [
            RewriteLine(type: .point, text: "Un punto"),
            RewriteLine(type: .definition, text: "Il {{m1|moat}} è un vantaggio"),
            RewriteLine(type: .example, text: "Per esempio un brevetto"),
        ])]
        let built = RewriteEditText.render(items: items)
        #expect(built.text.contains("def: Il moat è un vantaggio"))
        #expect(built.text.contains("ex: Per esempio un brevetto"))
        #expect(RewriteEditText.parse(text: built.text, spans: built.spans, originalItems: items) == items)
    }

    @MainActor
    @Test("an old kind == .definition goes into the Definizione style, without the 'Definition:' prefix and without falling back to Spiegazionebullet")
    func oldDefinitionItemExportsAsDefinitionLine() throws {
        var document = StoreFixtures.sampleDocumentRecord()
        document.blocks = [BlockRecord(id: "d1", sectionPath: [], pageStart: 0, pageEnd: 0, textHash: "hd1", words: 50)]
        document.toc = TocRecord(source: .native, entries: [])
        var analysis = AnalysisRecord()
        analysis.blocks["d1"] = BlockAnalysis(status: .analyzed, title: "D", rewrite: [RewriteItem(kind: .definition, text: "Un termine definito.")])
        let export = RewriteExportModel.build(document: document, analysis: analysis, scope: .wholeDocument, currentBlockId: nil)
        #expect(export.nodes.contains(.outlineLine(.definition, [RewriteExportRun(text: "Un termine definito.")])))
        #expect(!export.nodes.contains { if case .outlineLine(.explanation, _) = $0 { true } else { false } })
    }

    @MainActor
    @Test("copy and PDF: the two lines have their own rendering (left bar) and plain text uses Obsidian callouts")
    func copyAndPdfRendering() {
        let document = RewriteExportDocument(
            header: .init(documentTitle: "P", sectionLabel: "S", pagesLabel: "p. 1"),
            nodes: [
                .outlineLine(.definition, [.init(text: "Moat: a durable edge")]),
                .outlineLine(.example, [.init(text: "For instance, a patent")]),
            ]
        )
        let attributed = RewriteExportAttributedString.build(document).string
        #expect(attributed.contains("\u{258E}\tMoat: a durable edge"))
        #expect(attributed.contains("\u{258E}\tFor instance, a patent"))
        let plain = RewriteCopyExporter.plainText(for: document)
        #expect(plain.contains("> [!info] Moat: a durable edge"))
        #expect(plain.contains("> [!example] For instance, a patent"))
    }

    @Test("Markdown (Obsidian): the two outline lines come out as callouts")
    func markdownCallouts() {
        let item = RewriteItem(kind: .outline, lines: [
            RewriteLine(type: .definition, text: "Moat"), RewriteLine(type: .example, text: "Patent"),
        ])
        let markdown = MarkdownExporter.renderRewriteItem(item, marks: [])
        #expect(markdown.contains("> [!info] Moat") && markdown.contains("> [!example] Patent"))
    }
}
