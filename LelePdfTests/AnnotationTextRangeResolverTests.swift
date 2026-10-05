import Testing
import Foundation
@preconcurrency import PDFKit
@testable import LelePdf

/// Real selection → `textRange`/`quads` per page (SPEC §8, "selection →
/// textRange/quads per page, real Merck staged PDF, multi-page selection").
/// Same technique as `ManualSelectionResolverTests` (M7): direct
/// `page.selection(for:)`, without needing a real `PDFView`.
extension HeavyTestSuites {
@Suite("AnnotationTextRangeResolver+TextMarkup", .serialized)
@MainActor
struct AnnotationTextRangeResolverTests {
    private func nonEmptyPrefixRange(_ page: PDFPage, length: Int) -> NSRange? {
        guard let string = page.string, !string.isEmpty else { return nil }
        return NSRange(location: 0, length: min(length, (string as NSString).length))
    }

    @Test("a selection on a single page produces a textRange consistent with page.string")
    func singlePageRange() throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: Merck PDF not found at \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        guard let page = document.page(at: 0), let range = nonEmptyPrefixRange(page, length: 20),
              let selection = page.selection(for: range) else {
            print("SKIP: page 0 of the Merck PDF has no usable text")
            return
        }

        let lines = selection.selectionsByLine()
        let textRange = AnnotationTextRangeResolver.range(forLines: lines, page: page)
        let resolved = try #require(textRange)
        #expect(resolved.length > 0)
        #expect(resolved.start >= 0)

        // The text extracted from the resolved range must contain the first
        // words of the original selection (the textRange covers the whole span of
        // the lines found, and may be wider than `selection.string` because of
        // spaces at the start/end of a line).
        let pageString = try #require(page.string) as NSString
        #expect(resolved.start + resolved.length <= pageString.length)
        let extracted = pageString.substring(with: NSRange(location: resolved.start, length: resolved.length))
        if let firstWord = selection.string?.split(separator: " ").first {
            #expect(extracted.contains(firstWord))
        }
    }

    @Test("createTextMarkup from a multi-page selection creates one annotation per page")
    func multiPageSelectionCreatesOneAnnotationPerPage() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: Merck PDF not found at \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        guard document.pageCount >= 2,
              let page0 = document.page(at: 0), let page1 = document.page(at: 1),
              let range0 = nonEmptyPrefixRange(page0, length: 15),
              let range1 = nonEmptyPrefixRange(page1, length: 15),
              let selection0 = page0.selection(for: range0),
              let selection1 = page1.selection(for: range1) else {
            print("SKIP: first two pages of the Merck PDF have no usable text")
            return
        }
        selection0.add(selection1)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfAnnotationTextRangeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-textmarkup"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "merck.pdf", lastKnownPath: "/tmp/merck.pdf", title: "Merck", pageCount: document.pageCount)
        let controller = AnnotationController(store: store)
        controller.load(fingerprint: fingerprint, items: [])

        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: selection0, document: document, controller: controller)

        // SPEC: an annotation belongs to a single page: a selection over two
        // pages creates two annotations, one per page.
        #expect(controller.annotations.count == 2)
        #expect(Set(controller.annotations.map(\.page)) == [0, 1])
        for annotation in controller.annotations {
            #expect(annotation.kind == .highlight)
            #expect(!(annotation.quads ?? []).isEmpty)
        }
    }
}
}
