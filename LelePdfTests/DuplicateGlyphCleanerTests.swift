import Foundation
import Testing
@preconcurrency import PDFKit
@testable import LelePdf

/// Duplicated letters caused by simulated bold / an extraction defect:
/// "Buuildingg the Teeam" instead of "Building the Team", noticed on Ockham
/// Technologies (A): Building the Team.
extension HeavyTestSuites {
@Suite("DuplicateGlyphCleaner · duplicate letters", .serialized)
@MainActor
struct DuplicateGlyphCleanerTests {
    @Test("synthetic PDF: text redrawn with a minimal offset (faux bold) is not duplicated")
    func fauxBoldOverprintCollapses() throws {
        let url = try StoreFixtures.makeFauxBoldOverprintPDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))

        let layout = LineExtractor.extract(page: page, pageIndex: 0)
        let boldLineText = layout.lines.first?.text
        #expect(boldLineText == "Building the Team")
    }

    @Test("synthetic PDF: genuine double letters (Teeth, book) stay intact")
    func genuineDoubleLettersUntouched() throws {
        let url = try StoreFixtures.makeFauxBoldOverprintPDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))

        let layout = LineExtractor.extract(page: page, pageIndex: 0)
        #expect(layout.lines.count == 2)
        let plainLineText = layout.lines.last?.text
        #expect(plainLineText == "Teeth grow in book")
    }

    @Test("synthetic PDF: without overprint (a single drawn line) the text does not change")
    func noOverprintNoChange() throws {
        let url = try StoreFixtures.makeFauxBoldOverprintPDF(plainLine: nil)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Overwrites with a single line (no overprint): redrawn by hand
        // instead of adding another parameter to the fixture, using the same
        // technique as `StoreFixtures.makeTextPDF`.
        let singleURL = url.deletingLastPathComponent().appendingPathComponent("singola.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 500, height: 200)
        guard let consumer = CGDataConsumer(url: singleURL as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            Issue.record("could not create the test PDF")
            return
        }
        ctx.beginPDFPage(nil)
        let attributed = NSAttributedString(string: "Building the Team", attributes: [.font: NSFont.systemFont(ofSize: 18)])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 20, y: 140)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()

        let document = try #require(PDFDocument(url: singleURL))
        let page = try #require(document.page(at: 0))
        let layout = LineExtractor.extract(page: page, pageIndex: 0)
        #expect(layout.lines.first?.text == "Building the Team")
    }

    @Test("charOrigins maps each clean character to its original index")
    func charOriginsStaysConsistent() throws {
        let url = try StoreFixtures.makeFauxBoldOverprintPDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))

        let layout = LineExtractor.extract(page: page, pageIndex: 0)
        let boldLine = try #require(layout.lines.first)
        let origins = try #require(boldLine.charOrigins)
        #expect(origins.count == boldLine.text.count)
        // Each index must point to ONE real occurrence of the right character
        // in `page.string` (not necessarily contiguous: that is exactly the
        // point of this field).
        let pageString = try #require(page.string) as NSString
        for (offset, ch) in boldLine.text.enumerated() {
            let orig = origins[offset]
            let atOrig = pageString.substring(with: NSRange(location: orig, length: 1))
            #expect(atOrig == String(ch))
        }
        // The clean map stays shorter than the raw line range: confirms
        // something was really removed, not just that the text matches by
        // coincidence.
        #expect(origins.count < boldLine.charRange.length)
    }

    @Test("indexedText(for:) uses charOrigins when present")
    func indexedTextUsesCharOrigins() {
        let line = ExtractedLine(
            text: "and",
            charRange: CharRange(location: 100, length: 8),
            rect: .zero,
            fontSize: 12,
            isBold: false,
            superscriptRanges: [],
            charOrigins: [100, 101, 103]
        )
        let result = TextCleaner.indexedText(for: line)
        #expect(result.map(\.orig) == [100, 101, 103])
        #expect(result.string == "and")
    }

    @Test("indexedText(for:) rebuilds the contiguous map when charOrigins is nil (compatibility)")
    func indexedTextFallsBackWithoutCharOrigins() {
        let line = ExtractedLine(
            text: "and",
            charRange: CharRange(location: 100, length: 3),
            rect: .zero,
            fontSize: 12,
            isBold: false,
            superscriptRanges: []
        )
        let result = TextCleaner.indexedText(for: line)
        #expect(result.map(\.orig) == [100, 101, 102])
    }

    // MARK: - Confirmation on the real PDF

    @Test("real PDF (Ockham): the title lines no longer have duplicate letters with a spurious space")
    func realOckhamTitleFixed() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.ockham) else {
            print("SKIP: Ockham PDF not found at \(TestPDFs.ockham.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.ockham))
        let page = try #require(document.page(at: 0))
        let layout = LineExtractor.extract(page: page, pageIndex: 0)

        let allText = layout.lines.map(\.text).joined(separator: "\n")
        // Raw patterns known from the real PDF (verified with
        // `characterBounds(at:)` before the fix): they must no longer appear
        // in the extracted text. Limited to the first sentence (up to "for a
        // family wedding"): further down the same page the same "Oc" /
        // "ckham" split reappears across a genuine line break (different
        // lines/`PDFSelection`s, different Y), which is outside the scope of
        // this fix (see the comment on `abs(...midY...)` in
        // `DuplicateGlyphCleaner`, same treatment as "Te" / "eam" in the
        // title), so it must not make this check fail.
        let firstSentence = String(allText.prefix(while: { $0 != "." })) + "."
        for badPattern in ["Bu uilding", "Techn nolog", "Oc ckham", "T Techno", "Puerto o", "Jim m ", "an nd "] {
            #expect(!firstSentence.contains(badPattern), "broken pattern still present: \(badPattern)")
        }
        #expect(allText.contains("Ockham Technologies (A): Building the"))
        #expect(allText.contains("A U G U S T 1 0 , 2 0 1 1"), "the date must not double a digit (\"100\" instead of \"10\")")
        // False positive found during development: the "S S" of a
        // letter-spaced heading ("N O A M W A S S E R M A N") must NOT be
        // removed just because it has a space in between: it is a genuine
        // double, not the defect.
        #expect(allText.contains("N O A M W A S S E R M A N"), "the genuine double S of WASSERMAN must not disappear")
    }
}
}
