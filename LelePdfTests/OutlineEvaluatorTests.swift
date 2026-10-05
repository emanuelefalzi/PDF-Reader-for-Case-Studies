import Testing
@testable import LelePdf

/// Synthetic entries for the rules of SPEC §5.3, without touching PDFKit
/// (`OutlineEvaluator` is pure): see `NativeOutlineTests`/`ReaderIntegrationTests`
/// for the evaluation on the real test PDFs.
@Suite("OutlineEvaluator")
struct OutlineEvaluatorTests {
    private typealias Raw = OutlineEvaluator.RawEntry

    @Test("fewer than 3 entries → not useful")
    func tooFewEntries() {
        let entries = [Raw(title: "Capitolo 1", page: 0), Raw(title: "Capitolo 2", page: 10)]
        #expect(OutlineEvaluator.isUseful(entries: entries, pageCount: 100) == false)
    }

    @Test("less than 70% of entries with a valid page → not useful")
    func tooFewValidPages() {
        let entries = [
            Raw(title: "Capitolo 1", page: 0),
            Raw(title: "Capitolo 2", page: nil),
            Raw(title: "Capitolo 3", page: nil),
            Raw(title: "Capitolo 4", page: nil),
        ]
        #expect(OutlineEvaluator.isUseful(entries: entries, pageCount: 100) == false)
    }

    @Test("a label that looks like a file name → not useful")
    func fileLikeLabel() {
        let entries = [
            Raw(title: "EN_copyright page", page: 0),
            Raw(title: "Capitolo 2", page: 10),
            Raw(title: "Capitolo 3", page: 20),
        ]
        #expect(OutlineEvaluator.isUseful(entries: entries, pageCount: 100) == false)
    }

    @Test("coverage of 20% or less → not useful")
    func lowCoverage() {
        // Three entries all within the first 15 pages of a 100-page book: 15% coverage.
        let entries = [
            Raw(title: "Prefazione", page: 0),
            Raw(title: "Introduzione", page: 5),
            Raw(title: "Capitolo 1", page: 14),
        ]
        #expect(OutlineEvaluator.isUseful(entries: entries, pageCount: 100) == false)
    }

    @Test("valid outline → useful")
    func validOutline() {
        let entries = [
            Raw(title: "Capitolo 1", level: 1, page: 0),
            Raw(title: "1.1 Introduzione", level: 2, page: 2),
            Raw(title: "Capitolo 2", level: 1, page: 25),
            Raw(title: "Capitolo 3", level: 1, page: 50),
            Raw(title: "Capitolo 4", level: 1, page: 75),
        ]
        #expect(OutlineEvaluator.isUseful(entries: entries, pageCount: 100))
    }

    @Test("the Draghi case (SPEC §4): 2 entries, both file-name-like → not useful")
    func draghiLikeOutline() {
        let entries = [
            Raw(title: "EN_copyright page", page: 0),
            Raw(title: "EN_file", page: 1),
        ]
        #expect(OutlineEvaluator.isUseful(entries: entries, pageCount: 73) == false)
    }

    @Test("looksLikeFileName: positive cases")
    func fileNamePatternsPositive() {
        #expect(OutlineEvaluator.looksLikeFileName("EN_copyright page"))
        #expect(OutlineEvaluator.looksLikeFileName("qualcosa.pdf"))
        #expect(OutlineEvaluator.looksLikeFileName("Untitled"))
        #expect(OutlineEvaluator.looksLikeFileName("file"))
        #expect(OutlineEvaluator.looksLikeFileName("Vedi il FILE allegato"))
    }

    @Test("looksLikeFileName: 'file' inside another word does not trigger, as a whole word it does")
    func fileNamePatternsNegative() {
        #expect(OutlineEvaluator.looksLikeFileName("Capitolo 4 · L'obbligazione") == false)
        // "Profile" contains "file" but not as a whole word: SPEC §5.3 asks for
        // "file" as a whole word precisely so titles like this are not discarded.
        #expect(OutlineEvaluator.looksLikeFileName("Profile del debitore") == false)
        // "File system": "file" is a whole word, so it triggers anyway (a known
        // false positive, accepted by the simple rule of SPEC §5.3).
        #expect(OutlineEvaluator.looksLikeFileName("File system"))
    }
}
