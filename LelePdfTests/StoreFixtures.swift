import Foundation
@preconcurrency import PDFKit
@testable import LelePdf

/// Factories for the Store tests (SPEC §8, §11 row M3): a synthetic PDF with
/// real text (for the fingerprint) and sample records/analyses with every
/// kind of element, so the round-trip and export tests do not depend on the
/// real test PDFs.
@MainActor
enum StoreFixtures {
    /// A small PDF with real selectable text (CoreText), in its own temporary
    /// folder. The caller deletes the folder.
    static func makeTextPDF(text: String = "Ciao mondo, prova LelePdf.", fileName: String = "sintetico.pdf") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)

        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.beginPDFPage(nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 20, y: 150)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// A page with the SAME line drawn twice, at different positions: it
    /// reproduces "the same sentence appears twice on the page" for the
    /// `ManualSelectionResolver` tests without touching the real test PDFs
    /// (read-only, never copied into the repository).
    static func makeRepeatedLineTextPDF(line: String, fileName: String = "ripetuto.pdf") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)

        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 200)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.beginPDFPage(nil)
        let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 20, y: 150)
        CTLineDraw(ctLine, ctx)
        ctx.textPosition = CGPoint(x: 20, y: 60)
        CTLineDraw(ctLine, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// A multi-page PDF with different text on each page (to tell them apart
    /// by eye in tests), used by `ScrollSyncCurrentPageTests` (M10 part B) to
    /// verify current-page tracking with a real `PDFView`, not just generic
    /// `NSView`s like the rest of the `Sync/` suite.
    static func makeMultiPageTextPDF(pageCount: Int, pageSize: CGSize = CGSize(width: 300, height: 400), fileName: String = "multipagina.pdf") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for pageIndex in 0..<pageCount {
            ctx.beginPDFPage(nil)
            let attributed = NSAttributedString(string: "Pagina \(pageIndex + 1) di \(pageCount)", attributes: [.font: NSFont.systemFont(ofSize: 18)])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: 20, y: pageSize.height - 40)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// A line drawn in two strokes that overlap on ONE letter (faux-bold
    /// overprint): same geometry confirmed on the real PDF with
    /// `characterBounds(at:)` (the Ockham case, "Building the Team": "Bu" + a
    /// minimal offset + "uilding the Team" → `page.string` reads "Bu uilding
    /// the Team", with a spurious space between the two "u"s). It is not an
    /// identical redraw of the whole line: PDFKit treats two nearly identical
    /// strokes as two separate sentences (a huge position jump, not a small
    /// offset, between the end of the first and the start of the second); the
    /// real defect is this overlap on ONE letter with a forward advance,
    /// measured on the real case. `plainLine`, if given, is drawn below in a
    /// single stroke (real words with double letters, "Teeth"/"book": no
    /// letter must ever disappear).
    static func makeFauxBoldOverprintPDF(
        boldLine: String = "Building the Team",
        plainLine: String? = "Teeth grow in book",
        fileName: String = "grassetto-simulato.pdf"
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)

        var mediaBox = CGRect(x: 0, y: 0, width: 500, height: 200)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.beginPDFPage(nil)
        let font = NSFont.systemFont(ofSize: 18)
        precondition(boldLine.count > 2, "boldLine must have at least 3 characters")
        // "Bu" + "uilding the Team" (the second "u" repeats the last one of
        // "Bu"): same cut observed on the real PDF.
        let part1 = String(boldLine.prefix(2))
        let part2 = String(boldLine.dropFirst(1))
        let line1 = CTLineCreateWithAttributedString(NSAttributedString(string: part1, attributes: [.font: font]))
        let width1 = CGFloat(CTLineGetTypographicBounds(line1, nil, nil, nil))
        ctx.textPosition = CGPoint(x: 20, y: 140)
        CTLineDraw(line1, ctx)
        // Minimal forward offset (within a fraction of a character's width at
        // this font size, not a real space between words): the geometric
        // signature of the defect, not a gross repetition of the whole line.
        let line2 = CTLineCreateWithAttributedString(NSAttributedString(string: part2, attributes: [.font: font]))
        ctx.textPosition = CGPoint(x: 20 + width1 + 3, y: 140)
        CTLineDraw(line2, ctx)

        if let plainLine {
            let plainAttributed = NSAttributedString(string: plainLine, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            let plainCTLine = CTLineCreateWithAttributedString(plainAttributed)
            ctx.textPosition = CGPoint(x: 20, y: 80)
            CTLineDraw(plainCTLine, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    static func fingerprint(ofPDFAt url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        return DocumentFingerprint.compute(for: document)
    }

    // MARK: - Sample records/analyses with every element (SPEC §8)

    static func sampleBlocks() -> [BlockRecord] {
        [
            BlockRecord(id: "b1", sectionPath: ["Capitolo 1", "Sezione A"], pageStart: 0, pageEnd: 0, textHash: "hash1", words: 120),
            BlockRecord(id: "b2", sectionPath: ["Capitolo 1", "Sezione A"], pageStart: 1, pageEnd: 1, textHash: "hash2", words: 340),
        ]
    }

    static func sampleExhibits() -> [ExhibitRecord] {
        [ExhibitRecord(label: "Exhibit 5", page: 1)]
    }

    /// `colorTheme` (SPEC §5.4 v2.6, §8): `.verde` by default so the normal
    /// Codable round trip (`RecordsCodableTests.documentRecordRoundTrip`)
    /// already covers the "with a chosen color" case; `RecordsCodableTests`
    /// passes `nil` separately for the "without" case, plus a literal JSON
    /// lacking the key for backward compatibility (`documento.json` files
    /// written before v2.6).
    static func sampleDocumentRecord(fingerprint: String = "abc123def456", colorTheme: MaterialHue? = .verde) -> DocumentRecord {
        DocumentRecord(
            fingerprint: fingerprint,
            fileName: "documento.pdf",
            lastKnownPath: "/tmp/documento.pdf",
            pageCount: 3,
            title: "Documento di prova",
            toc: TocRecord(source: .native, entries: [
                TocEntryRecord(id: "t1", title: "Capitolo 1", level: 1, page: 0),
            ]),
            segmentationVersion: 1,
            blocks: sampleBlocks(),
            exhibits: sampleExhibits(),
            progress: ProgressRecord(analyzedBlockIds: ["b1"], lastReadPage: 2, lastAnalyzedBlockId: "b1"),
            updatedAt: Date(timeIntervalSince1970: 1_726_000_000),
            colorTheme: colorTheme
        )
    }

    /// Covers every `kind` of `RewriteItem`, every `MarkType`, a hidden mark
    /// and a marker with an unknown id (SPEC §8, Markdown export test "every
    /// element type, every mark type, hidden mark, unknown marker").
    static func sampleAnalysisRecord() -> AnalysisRecord {
        let marks = [
            Mark(id: "m1", termId: "term-rect", type: .rectangle, text: "spesa in R&S", source: .claude, page: 0, range: MarkRange(start: 0, length: 12)),
            Mark(id: "m2", termId: "term-circle", type: .circle, text: "Mario Rossi", source: .claude, page: 0, range: MarkRange(start: 20, length: 11)),
            Mark(id: "m3", termId: "term-underline", type: .underline, text: "ha deciso", source: .manual, page: 1, range: MarkRange(start: 0, length: 9)),
            Mark(id: "m4", termId: "term-arrow", type: .arrow, text: "ha causato", source: .claude, page: 1, range: MarkRange(start: 15, length: 10)),
            Mark(id: "m5", termId: "term-hidden", type: .rectangle, text: "segno nascosto", source: .manual, page: 0, range: MarkRange(start: 30, length: 14), hidden: true),
        ]
        let terms = [
            "term-rect": TermRecord(term: "spesa in R&S", type: .rectangle, firstBlockId: "b1"),
            "term-circle": TermRecord(term: "Mario Rossi", type: .circle, firstBlockId: "b1"),
            "term-underline": TermRecord(term: "ha deciso", type: .underline, firstBlockId: "b2"),
            "term-arrow": TermRecord(term: "ha causato", type: .arrow, firstBlockId: "b2"),
            "term-hidden": TermRecord(term: "segno nascosto", type: .rectangle, firstBlockId: "b1"),
        ]
        let links = [
            Link(id: "l1", from: "m3", to: "m4", label: "decisione", kind: .action, source: .claude),
        ]
        let rewriteB1: [RewriteItem] = [
            RewriteItem(kind: .summary, text: "Riassunto con {{m1|spesa in R&S}} e {{m2|Mario Rossi}}."),
            RewriteItem(kind: .definition, text: "Una definizione con marcatore sconosciuto {{m9|termine ignoto}}."),
            RewriteItem(kind: .bullets, items: ["Primo punto", "Secondo punto con {{m5|segno nascosto}}"]),
            RewriteItem(kind: .steps, items: ["Primo passo", "Secondo passo"]),
            RewriteItem(kind: .table, columns: ["Anno", "Valore"], rows: [["2024", "10"], ["2025", "20"]]),
            RewriteItem(kind: .callout, text: "Attenzione a questo punto."),
            RewriteItem(kind: .paragraph, text: "Un paragrafo semplice."),
        ]
        let rewriteB2: [RewriteItem] = [
            RewriteItem(kind: .summary, text: "Secondo blocco: {{m3|ha deciso}} e {{m4|ha causato}}."),
        ]
        let blocks: [String: BlockAnalysis] = [
            "b1": BlockAnalysis(status: .analyzed, analyzedAt: Date(timeIntervalSince1970: 1_726_000_000), model: "sonnet", title: "Primo blocco", rewrite: rewriteB1, rewriteEdited: false, claudeRewrite: rewriteB1, marks: marks, links: []),
            "b2": BlockAnalysis(status: .analyzed, analyzedAt: Date(timeIntervalSince1970: 1_726_000_100), model: "sonnet", title: "Secondo blocco", rewrite: rewriteB2, rewriteEdited: true, claudeRewrite: rewriteB2, marks: [marks[2], marks[3]], links: links),
        ]
        return AnalysisRecord(blocks: blocks, terms: terms)
    }
}
