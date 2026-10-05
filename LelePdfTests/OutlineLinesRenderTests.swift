import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// F7 (Word-style lines; "each type has a distinct rendering ... no overlap at
/// 320-700 pt"): a `kind == .outline` card with every line type (point,
/// sub-point, explanation, note, formula, consequence, subheading, plus
/// definition and example added in F18) does not overlap neighboring text at
/// any width between 320 and 700 pt, has positive height, and exports a PNG for
/// visual review. Same harness as `BulletsSubItemsRenderTests`, REAL
/// components (`CardContainer`/`RewriteItemView`).
extension HeavyTestSuites {
@MainActor
@Suite("Outline card (F7) · all line types, no overlap at 320-700pt", .serialized)
struct OutlineLinesRenderTests {
    private func block(_ id: String, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: 0, pageEnd: 0, cleanText: text, textHash: id, words: text.split(separator: " ").count, spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    private func makeModelWithOutlineCard() throws -> (model: DocumentModel, items: [AnalysisController.ResolvedRewriteItem]) {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per i tipi di riga F7.", fileName: "outline-lines-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "outline-lines-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let lines: [RewriteLine] = [
            RewriteLine(type: .point, text: "{{m1|Vioxx}} viene approvato dalla FDA nel 1999."),
            RewriteLine(type: .subpoint, text: "Sostituisce parzialmente i FANS più vecchi."),
            RewriteLine(type: .explanation, text: "In pratica riduce gli effetti collaterali gastrointestinali per chi è a rischio."),
            RewriteLine(type: .note, text: "Nota: il nome commerciale varia da paese a paese."),
            RewriteLine(type: .formula, text: "rischio relativo = eventi trattati / eventi controllo"),
            // Definition and example, the two newer line types.
            RewriteLine(type: .definition, text: "Inibitore COX-2: un farmaco che blocca in modo selettivo l'enzima responsabile dell'infiammazione."),
            RewriteLine(type: .example, text: "Per esempio, un paziente con artrite cronica che non tollera i FANS tradizionali."),
            RewriteLine(type: .consequence, text: "Il farmaco viene ritirato dal mercato nel settembre 2004."),
            RewriteLine(type: .subheading, text: "Il ritiro e le sue conseguenze legali"),
            RewriteLine(type: .point, text: "Migliaia di cause civili seguono il ritiro."),
        ]
        var analysis = AnalysisRecord()
        analysis.terms["t1"] = TermRecord(term: "Vioxx", type: .circle, firstBlockId: "b1")
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Prova tipi di riga",
            rewrite: [RewriteItem(kind: .outline, lines: lines)],
            marks: [Mark(id: "m1", termId: "t1", type: .circle, text: "Vioxx", source: .claude, page: 0, range: MarkRange(start: 0, length: 5))]
        )
        let blockText = lines.map(\.text).joined(separator: " ")
        model.analysisController.updateContext(
            fingerprint: "fp-outline-lines", documentTitle: "Documento di prova", blocks: [block("b1", text: blockText)],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )
        let cardItems = try #require(model.analysisController.cardData(for: "b1")?.rewrite)
        return (model, cardItems)
    }

    private func measure(panelWidth: CGFloat, pngName: String) throws -> [Int: CGRect] {
        try expectFootprintGrowthUnderGuard("OutlineLinesRenderTests.measure(\(Int(panelWidth))pt)") {
            let (model, items) = try makeModelWithOutlineCard()
            var collected: [Int: CGRect] = [:]
            let probe = AnyView(
                CardItemsProbe(items: items, model: model, blockId: "b1") { collected = $0 }
                    .frame(width: panelWidth, alignment: .leading)
                    .background(Color.white)
            )
            let hostingView = NSHostingView(rootView: probe)
            hostingView.frame = CGRect(x: 0, y: 0, width: panelWidth, height: 1)
            let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
            defer { closeTestWindow(window) }
            window.isReleasedWhenClosed = false
            window.contentView = hostingView

            hostingView.layoutSubtreeIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            let fitting = hostingView.fittingSize
            hostingView.frame = CGRect(x: 0, y: 0, width: panelWidth, height: max(1, fitting.height))
            window.setContentSize(hostingView.frame.size)
            hostingView.layoutSubtreeIfNeeded()
            hostingView.layoutSubtreeIfNeeded()

            let outputRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            exportPNG(hostingView, to: outputRoot.appendingPathComponent(pngName))
            return collected
        }
    }

    @Test(
        "320-700pt: the card with all F7 line types has positive height and exports a readable PNG",
        arguments: [CGFloat(320), CGFloat(400), CGFloat(520), CGFloat(600), CGFloat(700)]
    )
    func allLineTypesNeverOverlapOrClip(panelWidth: CGFloat) throws {
        let frames = try measure(panelWidth: panelWidth, pngName: "outline-lines-\(Int(panelWidth))pt.png")
        let outlineFrame = try #require(frames[0], "missing outline card frame at \(panelWidth) pt")
        #expect(outlineFrame.height > 0, "outline card with zero height at \(panelWidth) pt")

        // 10 lines of real content (one of them a subheading, one a formula
        // centered over several lines): it cannot fit in less than ~140 pt at
        // any width between 320 and 700 pt. Same indirect measure as
        // `BulletsSubItemsRenderTests` for "clipped/overlapping text".
        let minPlausibleHeight: CGFloat = 140
        #expect(outlineFrame.height >= minPlausibleHeight, "suspiciously low height (\(outlineFrame.height) pt) for 10 lines at \(panelWidth) pt; possible clipped/overlapping text")
    }
}
}
