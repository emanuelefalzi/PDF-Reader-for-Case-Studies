import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// User request: "bullet points and sub-bullet points ... paragraph by
/// paragraph": the card with bullets AND sub-bullets (`RewriteItem.subItems`)
/// must stay readable — no overlapping or clipped text — at ANY width between
/// 320 and 700 pt, and the two levels must stay visually distinguishable.
/// Same harness/PNG as `CardItemOverlapTests` (`exportPNG`,
/// `ItemFramesPreferenceKey`, `CardItemsProbe`): REAL card components
/// (`CardContainer`/`RewriteItemView`), not a separate reconstruction.
extension HeavyTestSuites {
@MainActor
@Suite("Card with sub-bullets · no overlap/clipping 320-700pt", .serialized)
struct BulletsSubItemsRenderTests {
    private func block(_ id: String, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: 0, pageEnd: 0, cleanText: text, textHash: id, words: text.split(separator: " ").count, spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    /// Realistic "paragraph by paragraph" content: 3 main points (one short
    /// with no sub-bullets, two dense ones with 2-4 sub-bullets each), with
    /// `circle` marks on numbers/proper names (bold) to also check the
    /// typographic emphasis when reading the PNG.
    private func makeModelWithBulletsCard() throws -> (model: DocumentModel, items: [AnalysisController.ResolvedRewriteItem]) {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per punti e sottopunti.", fileName: "bullets-subitems-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "bullets-subitems-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let summary = "Il Merck Manual descrive tre fasi dello sviluppo clinico di {{m1|Vioxx}} fra il 1997 e il 2004."
        let items = [
            "{{m1|Vioxx}} viene approvato dalla {{m2|FDA}} nel {{m3|1999}} come antinfiammatorio con minori effetti gastrointestinali.",
            "Gli studi post-marketing rilevano un aumento del rischio cardiovascolare negli utilizzatori a lungo termine.",
            "{{m4|Merck}} ritira volontariamente il farmaco dal mercato nel {{m5|settembre 2004}}.",
        ]
        let subItems: [[String]] = [
            [
                "Sostituisce parzialmente {{m2|FDA}}-approved FANS più vecchi per pazienti a rischio gastrointestinale.",
                "Le vendite superano i {{m3|2,5 miliardi di dollari}} annui entro il 2000.",
            ],
            [
                "Lo studio VIGOR (2000) mostra un tasso di eventi cardiovascolari quattro volte superiore al naprossene.",
                "{{m2|FDA}} richiede un'avvertenza sulla scatola nel 2002.",
                "Lo studio APPROVe (2004) conferma il rischio raddoppiato dopo 18 mesi di uso continuo.",
                "Le associazioni di pazienti chiedono un richiamo immediato del farmaco.",
            ],
            [],
        ]
        var analysis = AnalysisRecord()
        analysis.terms["t1"] = TermRecord(term: "Vioxx", type: .circle, firstBlockId: "b1")
        analysis.terms["t2"] = TermRecord(term: "FDA", type: .circle, firstBlockId: "b1")
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Ascesa e ritiro del Vioxx",
            rewrite: [
                RewriteItem(kind: .summary, text: summary),
                RewriteItem(kind: .bullets, items: items, subItems: subItems),
            ],
            marks: [
                Mark(id: "m1", termId: "t1", type: .circle, text: "Vioxx", source: .claude, page: 0, range: MarkRange(start: 0, length: 5)),
                Mark(id: "m2", termId: "t2", type: .circle, text: "FDA", source: .claude, page: 0, range: MarkRange(start: 10, length: 3)),
                Mark(id: "m3", termId: "t2", type: .circle, text: "1999", source: .claude, page: 0, range: MarkRange(start: 20, length: 4)),
                Mark(id: "m4", termId: "t2", type: .circle, text: "Merck", source: .claude, page: 0, range: MarkRange(start: 30, length: 5)),
                Mark(id: "m5", termId: "t2", type: .circle, text: "settembre 2004", source: .claude, page: 0, range: MarkRange(start: 40, length: 14)),
            ]
        )
        let blockText = ([summary] + items + subItems.flatMap { $0 }).joined(separator: " ")
        model.analysisController.updateContext(
            fingerprint: "fp-bullets-subitems", documentTitle: "Documento di prova", blocks: [block("b1", text: blockText)],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )
        let cardItems = try #require(model.analysisController.cardData(for: "b1")?.rewrite)
        return (model, cardItems)
    }

    private func measure(panelWidth: CGFloat, pngName: String) throws -> [Int: CGRect] {
        // Per-test footprint guard: window + real rendering + PNG export for
        // each of the 5 parameterized widths.
        try expectFootprintGrowthUnderGuard("BulletsSubItemsRenderTests.measure(\(Int(panelWidth))pt)") {
            let (model, items) = try makeModelWithBulletsCard()
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
        "320-700pt: the 'bullets' block with sub-bullets does not overlap the summary, has positive height, and exports a readable PNG",
        arguments: [CGFloat(320), CGFloat(400), CGFloat(520), CGFloat(600), CGFloat(700)]
    )
    func bulletsWithSubItemsNeverOverlapOrClip(panelWidth: CGFloat) throws {
        let frames = try measure(panelWidth: panelWidth, pngName: "bullets-subitems-\(Int(panelWidth))pt.png")
        let summaryFrame = try #require(frames[0], "missing summary frame at \(panelWidth) pt")
        let bulletsFrame = try #require(frames[1], "missing bullets frame at \(panelWidth) pt")

        #expect(summaryFrame.height > 0, "summary with zero height at \(panelWidth) pt")
        #expect(bulletsFrame.height > 0, "bullets with zero height at \(panelWidth) pt")
        #expect(!summaryFrame.intersects(bulletsFrame), "summary and bullets overlap at \(panelWidth) pt: \(summaryFrame) vs \(bulletsFrame)")

        // A block with 3 main points (one of 1 line, two with 2-4 sub-bullets
        // each, ~90+ words in all) cannot fit in fewer than ~10 lines of text at
        // ANY width between 320 and 700 pt: a much lower value is an indirect sign
        // of clipped text or of elements stacked on top of each other instead of
        // in sequence (an indirect measure, the same idea as
        // `CardItemOverlapTests` "sum of heights against the total content
        // height").
        let minPlausibleHeight: CGFloat = 90
        #expect(bulletsFrame.height >= minPlausibleHeight, "suspiciously low height (\(bulletsFrame.height) pt) for 3 points + 6 sub-bullets at \(panelWidth) pt — possible clipped/overlapping text")
    }
}
}
