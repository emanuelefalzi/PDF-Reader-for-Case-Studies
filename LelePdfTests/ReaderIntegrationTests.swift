import Testing
import Foundation
@preconcurrency import PDFKit
@testable import LelePdf

/// Integration tests with the two real test PDFs (SPEC §4, §11 row M1).
/// Read-only; they skip with a message if the file is missing or not yet
/// downloaded from iCloud.
extension HeavyTestSuites {
@Suite("Reader · test PDFs", .serialized)
@MainActor
struct ReaderIntegrationTests {
    @Test("the Draghi report's native outline is judged not useful")
    func draghiOutlineNotUseful() throws {
        guard TestPDFs.ensureAvailable(TestPDFs.draghi) else {
            print("SKIP: PDF Draghi not found in \(TestPDFs.draghi.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.draghi))
        let raw = NativeOutline.extractRaw(from: document)
        #expect(OutlineEvaluator.isUseful(entries: raw, pageCount: document.pageCount) == false)
    }

    @Test("the Merck case has no built-in outline")
    func merckHasNoOutline() throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found in \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        let raw = NativeOutline.extractRaw(from: document)
        #expect(OutlineEvaluator.isUseful(entries: raw, pageCount: document.pageCount) == false)
    }

    @Test("searching for 'Orphan Drug Act' in the Merck case finds results, in both scopes")
    func merckSearchFindsOrphanDrugAct() throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found in \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))

        let wholeDocument = SearchService.find("Orphan Drug Act", in: document, pageRange: nil)
        #expect(wholeDocument.count >= 1)

        // The Merck case has no outline (verified above): the "Capitolo"
        // (chapter) scope falls back to the whole PDF, per SPEC §5.10.
        let raw = NativeOutline.extractRaw(from: document)
        let tocEntries = OutlineEvaluator.isUseful(entries: raw, pageCount: document.pageCount)
            ? NativeOutline.extractEntries(from: document)
            : []
        let chapterRange = TocNavigation.chapterPageRange(entries: tocEntries, page: 0, pageCount: document.pageCount)
        #expect(chapterRange == nil)

        let chapterScoped = SearchService.find("Orphan Drug Act", in: document, pageRange: chapterRange)
        #expect(chapterScoped.count >= 1)
        #expect(chapterScoped.count == wholeDocument.count)
    }

    @Test("opening the two test PDFs takes less than 1 s (SPEC §11 row M1)")
    func opensWithinOneSecond() throws {
        for url in [TestPDFs.draghi, TestPDFs.merck] {
            guard TestPDFs.ensureAvailable(url) else {
                print("SKIP: PDF not found in \(url.path)")
                continue
            }
            let start = Date()
            let document = try #require(PDFDocument(url: url))
            _ = document.page(at: 0)
            let elapsed = Date().timeIntervalSince(start)
            #expect(elapsed < 1.0, "opening \(url.lastPathComponent) took \(elapsed) s, over the 1 s threshold")
        }
    }
}
}
