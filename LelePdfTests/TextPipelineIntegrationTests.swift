import Foundation
import Testing
@preconcurrency import PDFKit
@testable import LelePdf

/// Integration tests of the text pipeline on the two real test PDFs (SPEC §11
/// row M2). Read-only; they skip with a message if the file is missing or not
/// yet downloaded from iCloud.
extension HeavyTestSuites {
@Suite("Pipeline · test PDFs", .serialized)
@MainActor
struct TextPipelineIntegrationTests {
    @Test("batched extraction identical to the historical path on the two real PDFs")
    func batchedExtractionPreservesAllPipelineOutputs() async throws {
        for url in [TestPDFs.merck, TestPDFs.draghi] {
            guard TestPDFs.ensureAvailable(url) else {
                print("SKIP: PDF not found at \(url.path)")
                continue
            }
            let data = try Data(contentsOf: url)
            let historicalDocument = try #require(PDFDocument(data: data))

            // Reproduces the earlier path: the fingerprint used to warm up
            // all the pages of the same document before `LineExtractor`.
            for pageIndex in 0 ..< historicalDocument.pageCount {
                _ = historicalDocument.page(at: pageIndex)?.string
            }
            var historicalLayouts: [PageLayout] = []
            historicalLayouts.reserveCapacity(historicalDocument.pageCount)
            for pageIndex in 0 ..< historicalDocument.pageCount {
                if let page = historicalDocument.page(at: pageIndex) {
                    historicalLayouts.append(LineExtractor.extract(page: page, pageIndex: pageIndex))
                }
            }

            let batchedDocument = try #require(PDFDocument(data: data))
            let batchedExtraction = await PipelineRunner.extractInBatchesWithPageTexts(
                sourceData: data,
                fallbackDocument: batchedDocument,
                pageCount: batchedDocument.pageCount,
                prioritizedPageRange: 0 ... max(0, batchedDocument.pageCount - 1)
            )
            let batchedLayouts = batchedExtraction.layouts
            #expect(batchedLayouts == historicalLayouts, "layouts differ for \(url.lastPathComponent)")
            #expect(
                DocumentFingerprint.compute(pageCount: batchedDocument.pageCount, pageTexts: batchedExtraction.pageTexts)
                    == DocumentFingerprint.compute(for: historicalDocument),
                "combined fingerprint differs for \(url.lastPathComponent)"
            )

            let historical = await TextPipeline().process(layouts: historicalLayouts)
            let batched = await TextPipeline().process(layouts: batchedLayouts)
            #expect(batched.headings == historical.headings)
            #expect(batched.tocCandidates == historical.tocCandidates)
            #expect(batched.exhibits == historical.exhibits)
            #expect(batched.blocks == historical.blocks)
            #expect(batched.removedHeaderFooterLines == historical.removedHeaderFooterLines)
        }
    }

    @Test("Draghi header removed on at least 95% of the pages that have one")
    func draghiHeaderRemoved() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.draghi) else {
            print("SKIP: PDF Draghi not found at \(TestPDFs.draghi.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.draghi))
        let result = await PipelineRealDocumentHelper.run(document)

        let cleanPages = result.layouts.map(CleanPage.init(layout:))
        let headerResult = HeaderFooterRemover.apply(to: cleanPages)

        var pagesWithTopLine = 0
        var pagesWithTopLineRemoved = 0
        for page in headerResult.pages {
            let topThreshold = page.pageRect.minY + page.pageRect.height * (1 - HeaderFooterRemover.marginFraction)
            let topLines = page.lines.filter { $0.rect.minY >= topThreshold }
            guard !topLines.isEmpty else { continue }
            pagesWithTopLine += 1
            if topLines.contains(where: \.removedAsHeaderFooter) { pagesWithTopLineRemoved += 1 }
        }
        let ratio = pagesWithTopLine == 0 ? 0 : Double(pagesWithTopLineRemoved) / Double(pagesWithTopLine)
        print("Draghi: header removed on \(pagesWithTopLineRemoved)/\(pagesWithTopLine) pages with a header (\(ratio * 100)%)")
        #expect(ratio >= 0.95)
    }

    @Test("'connectivity' is rejoined, 'connec-' does not remain in the Draghi clean text")
    func connectivityJoined() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.draghi) else {
            print("SKIP: PDF Draghi not found at \(TestPDFs.draghi.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.draghi))
        let result = await PipelineRealDocumentHelper.run(document)
        let allText = result.output.blocks.map(\.cleanText).joined(separator: " ")
        #expect(allText.localizedCaseInsensitiveContains("connectivity"))
        #expect(!allText.contains("connec-"))
    }

    @Test("license line of the Merck case removed on all pages")
    func merckLicenseLineRemoved() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found at \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        let result = await PipelineRealDocumentHelper.run(document)

        let cleanPages = result.layouts.map(CleanPage.init(layout:))
        let headerResult = HeaderFooterRemover.apply(to: cleanPages)

        var pagesWithMarginLine = 0
        var pagesRemoved = 0
        for page in headerResult.pages {
            let topThreshold = page.pageRect.minY + page.pageRect.height * (1 - HeaderFooterRemover.marginFraction)
            let bottomThreshold = page.pageRect.minY + page.pageRect.height * HeaderFooterRemover.marginFraction
            let marginLines = page.lines.filter { $0.rect.minY >= topThreshold || $0.rect.maxY <= bottomThreshold }
            guard !marginLines.isEmpty else { continue }
            pagesWithMarginLine += 1
            if marginLines.contains(where: \.removedAsHeaderFooter) { pagesRemoved += 1 }
        }
        let ratio = pagesWithMarginLine == 0 ? 0 : Double(pagesRemoved) / Double(pagesWithMarginLine)
        print("Merck: margin line removed on \(pagesRemoved)/\(pagesWithMarginLine) pages (\(ratio * 100)%)")
        #expect(ratio >= 0.95)
    }

    @Test("Exhibits of the Merck case detected")
    func merckExhibitsDetected() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found at \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        let result = await PipelineRealDocumentHelper.run(document)
        print("Merck: Exhibits found: \(result.output.exhibits.map(\.label))")
        #expect(result.output.exhibits.count >= 2)
    }

    @Test("the blocks of the Merck case respect the length rules")
    func merckBlocksWithinRules() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found at \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        let result = await PipelineRealDocumentHelper.run(document)
        #expect(!result.output.blocks.isEmpty)
        for block in result.output.blocks {
            #expect(block.words > 0, "empty block: \(block.id)")
            #expect(block.words <= 1500, "block too long (\(block.words) words): \(block.id)")
            #expect(block.pageEnd >= block.pageStart)
        }
    }

    @Test("contents candidates include the Draghi chapters")
    func draghiTocCandidatesIncludeChapters() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.draghi) else {
            print("SKIP: PDF Draghi not found at \(TestPDFs.draghi.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.draghi))
        let result = await PipelineRealDocumentHelper.run(document)
        let chapterTitles = result.output.tocCandidates.filter {
            $0.title.range(of: "^Chapter [0-9]+$", options: .regularExpression) != nil
        }
        print("Draghi: chapter candidates: \(chapterTitles.map(\.title))")
        #expect(chapterTitles.count >= 2)
    }

    @Test("a block that straddles a page boundary resolves the right pages")
    func crossPageBlockResolvesCorrectPages() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.draghi) else {
            print("SKIP: PDF Draghi not found at \(TestPDFs.draghi.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.draghi))
        let result = await PipelineRealDocumentHelper.run(document)
        guard let crossPageBlock = result.output.blocks.first(where: { $0.pageStart != $0.pageEnd }) else {
            print("SKIP: no page-straddling block found in the Draghi")
            return
        }
        let fullRange = NSRange(location: 0, length: crossPageBlock.cleanText.count)
        let resolved = crossPageBlock.resolve(cleanRange: fullRange)
        let pages = Set(resolved.map(\.page))
        #expect(pages.count >= 2)
        #expect(pages.contains(crossPageBlock.pageStart))
        #expect(pages.contains(crossPageBlock.pageEnd))
    }

    @Test("Merck section headings detected with correct page and level (M2/M4 fix)")
    func merckSectionHeadingsDetected() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found at \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        let result = await PipelineRealDocumentHelper.run(document)
        let byText = Dictionary(result.output.headings.map { ($0.text, $0) }, uniquingKeysWith: { first, _ in first })
        print("Merck: headings found: \(result.output.headings.map { "\($0.text) (p.\($0.pageIndex + 1), level \($0.level))" })")

        // Real font inspection (PDFPage.attributedString): body
        // Palatino-Roman 9.96; sections Palatino-Bold 12.96 (level 1);
        // subsections Palatino-Italic 12.0 (level 2).
        let expectedLevel1: [(String, Int)] = [
            ("Industry Size and Composition", 0),
            ("Developing a Drug", 1),
            ("Manufacturing Drugs", 4),
            ("Merck & Co.", 8),
        ]
        for (title, pageIndex) in expectedLevel1 {
            let heading = try #require(byText[title], "heading not found: \(title)")
            #expect(heading.pageIndex == pageIndex, "\(title): expected page \(pageIndex + 1), found \(heading.pageIndex + 1)")
            #expect(heading.level == 1, "\(title): expected level 1, found \(heading.level)")
        }

        let theProcess = try #require(byText["The Process"], "heading not found: The Process")
        #expect(theProcess.pageIndex == 2)
        #expect(theProcess.level == 2)

        // The cover title must not appear as a section title (fixed bug: it
        // consumed level 1).
        #expect(!result.output.headings.contains { $0.text.contains("Twenty-First Century") })
    }

    @Test("the Merck contents candidates include the section headings, not just the title")
    func merckTocCandidatesIncludeSectionHeadings() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found at \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        let result = await PipelineRealDocumentHelper.run(document)
        let titles = Set(result.output.tocCandidates.map(\.title))
        print("Merck: contents candidates: \(result.output.tocCandidates.map(\.title))")
        // Before the fix this set had a single entry (the document title):
        // now it must contain the real sections.
        #expect(titles.contains("Industry Size and Composition"))
        #expect(titles.contains("Developing a Drug"))
        #expect(titles.contains("The Process"))
        #expect(titles.contains("Manufacturing Drugs"))
        #expect(titles.contains("Merck & Co."))
        #expect(result.output.tocCandidates.count > 1)
    }

    @Test("the Merck blocks respect the section boundaries of the real headings")
    func merckBlocksRespectRealSectionBoundaries() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: PDF Merck not found at \(TestPDFs.merck.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.merck))
        let result = await PipelineRealDocumentHelper.run(document)

        let expected: [(String, Int)] = [
            ("Industry Size and Composition", 0),
            ("Developing a Drug", 1),
            ("The Process", 2),
            ("Manufacturing Drugs", 4),
            ("Merck & Co.", 8),
        ]
        for (title, pageIndex) in expected {
            let matching = result.output.blocks.filter { $0.sectionPath.last == title }
            #expect(!matching.isEmpty, "no block with a sectionPath ending in '\(title)'")
            for block in matching {
                #expect(block.pageStart >= pageIndex, "block of '\(title)' starts before its section: p.\(block.pageStart + 1)")
            }
        }

        // No block crosses a boundary between two of these sections: the
        // title of another known section never appears in the text of this
        // one's blocks.
        for (title, _) in expected {
            let otherTitles = expected.map(\.0).filter { $0 != title }
            for block in result.output.blocks where block.sectionPath.last == title {
                for other in otherTitles {
                    #expect(!block.cleanText.contains(other), "the block of '\(title)' contains text of '\(other)'")
                }
            }
        }
    }

    @Test("two DIFFERENT headings on the same page (Merck or Draghi) give distinct pageY values, not the same one")
    func distinctPageYForTwoHeadingsOnSamePage() async throws {
        var found = false
        for url in [TestPDFs.merck, TestPDFs.draghi] {
            guard TestPDFs.ensureAvailable(url) else {
                print("SKIP: PDF not found at \(url.path)")
                continue
            }
            let document = try #require(PDFDocument(url: url))
            let result = await PipelineRealDocumentHelper.run(document)
            // Grouped by page and sorted by page index (not a bare
            // `Dictionary`: iteration order is not guaranteed and made this
            // test unstable, a different page on every run). One entry per
            // distinct NORMALIZED title: two lines with the same text (e.g. a
            // table with repeated labels) are not the "two different
            // headings" case of the bug, and matching by text cannot tell
            // them apart anyway (an intrinsic limit, not a regression).
            let byPage = Dictionary(grouping: result.output.headings, by: \.pageIndex)
            let firstUsablePage = byPage.keys.sorted().first { pageIndex in
                let distinctTitles = Set((byPage[pageIndex] ?? []).map { TermRegistry.normalize($0.text) })
                return distinctTitles.count >= 2
            }
            guard let pageIndex = firstUsablePage else { continue }
            var seenTitles: Set<String> = []
            let headingsOnPage = (byPage[pageIndex] ?? []).filter { seenTitles.insert(TermRegistry.normalize($0.text)).inserted }
            found = true
            print("\(url.lastPathComponent): page \(pageIndex + 1) with \(headingsOnPage.count) distinct headings: \(headingsOnPage.map(\.text))")

            // Reported bug: "there are two headings on the same page, it only
            // takes me to the first one that appears". Each heading, looked
            // up with its own exact text (as a generated entry already
            // cleaned up by Claude would be), must return to ITS line, not
            // always the same one. Tolerance on the floating-point
            // comparison: `CGFloat`/`Double` can differ by a negligible
            // epsilon between two conversions of the same `rect.maxY`.
            var seenPageY: [Double] = []
            for heading in headingsOnPage {
                let pageY = try #require(
                    TocHeadingMatch.pageY(forTitle: heading.text, pageIndex: pageIndex, headings: result.output.headings),
                    "no match for '\(heading.text)'"
                )
                #expect(abs(pageY - Double(heading.rect.maxY)) < 0.01, "'\(heading.text)' matched to the wrong line")
                #expect(!seenPageY.contains { abs($0 - pageY) < 0.01 }, "distinct headings on the same page resolved to the same pageY")
                seenPageY.append(pageY)
            }
        }
        if !found { print("SKIP: no page with ≥2 DIFFERENT headings found in Merck/Draghi") }
    }

    @Test("complete Draghi pipeline under 5 s (SPEC §9)")
    func draghiPipelineUnderFiveSeconds() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.draghi) else {
            print("SKIP: PDF Draghi not found at \(TestPDFs.draghi.path)")
            return
        }
        let document = try #require(PDFDocument(url: TestPDFs.draghi))
        let result = await PipelineRealDocumentHelper.run(document)
        print("Draghi: complete pipeline in \(result.elapsed) s (\(document.pageCount) pages)")
        #expect(result.elapsed < 5.0)
    }
}
}
