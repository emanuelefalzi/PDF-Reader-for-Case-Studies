import Foundation
@preconcurrency import PDFKit

/// Coordinates the extraction (MainActor, in small batches with
/// `Task.yield()`, visible pages before the others; SPEC §7.1, §9) and the
/// cleaning/structure (`actor TextPipeline`), then publishes the result in
/// `DocumentModel.structure` (SPEC §5.2: it starts after the first page is
/// shown, never blocking the open). It also manages the layout cache
/// (SPEC §7.1) and the fingerprint (SPEC §8, also used by M3).
@MainActor
enum PipelineRunner {
    private static let batchSize = 6
    /// `JSONDecoder` must materialize the whole `layout.json` in one go; on
    /// a 600-page cache this leaves ~60 MB more of high-water mark than the
    /// new batched extraction (measured: 365-367 MB against 303 MB for the
    /// whole app). The real PDFs known so far reach ~100 pages and keep
    /// benefiting from the cache; beyond this threshold it is safer to
    /// regenerate in batches, without saving a file that on reopen would push
    /// the app past the desired memory profile.
    private static let maximumLayoutCachePageCount = 200

    static func shouldUseLayoutCache(pageCount: Int) -> Bool {
        pageCount <= maximumLayoutCachePageCount
    }

    static func run(model: DocumentModel) {
        guard model.pipelineState == .idle else { return }
        model.pipelineState = .running(progress: 0)

        Task {
            let document = model.pdfDocument
            let sourceData = model.sourceData
            let pageCount = document.pageCount
            guard pageCount > 0 else {
                model.pipelineState = .ready
                return
            }
            let fingerprint: String
            let layouts: [PageLayout]
            let usesLayoutCache = shouldUseLayoutCache(pageCount: pageCount)
            if usesLayoutCache {
                // Do not compute the fingerprint on the `PDFDocument` shown by
                // the reader: reading `.string` on all the pages of that
                // instance keeps PDFKit's internal caches resident for the
                // whole life of the window.
                fingerprint = DocumentFingerprint.computeBatched(
                    data: sourceData,
                    expectedPageCount: pageCount,
                    batchSize: batchSize
                ) ?? DocumentFingerprint.compute(for: document)

                if let cached = LayoutCache.load(fingerprint: fingerprint), cached.count == pageCount {
                    layouts = cached
                } else {
                    let extracted = await extractInBatches(
                        sourceData: sourceData,
                        fallbackDocument: document,
                        pageCount: pageCount,
                        prioritizedPageRange: model.visiblePageRange
                    ) { progress in
                        model.pipelineState = .running(progress: progress)
                    }
                    LayoutCache.save(fingerprint: fingerprint, layouts: extracted)
                    layouts = extracted
                }
            } else {
                // For long documents, which do not use the JSON cache, the
                // fingerprint text and the layout come from the SAME batched
                // pass. The raw strings stay alive only until the SHA-256 and
                // are not published in `DocumentStructure`.
                let extracted = await extractInBatchesWithPageTexts(
                    sourceData: sourceData,
                    fallbackDocument: document,
                    pageCount: pageCount,
                    prioritizedPageRange: model.visiblePageRange
                ) { progress in
                    model.pipelineState = .running(progress: progress)
                }
                fingerprint = DocumentFingerprint.compute(pageCount: pageCount, pageTexts: extracted.pageTexts)
                layouts = extracted.layouts
            }

            let textless = TextlessDetector.isTextless(pageTextLengths: layouts.map(\.stringLength))
            let output = await TextPipeline().process(layouts: layouts)

            let structure = DocumentStructure(
                fingerprint: fingerprint,
                pageCount: pageCount,
                headings: output.headings,
                tocCandidates: output.tocCandidates,
                exhibits: output.exhibits,
                blocks: output.blocks,
                textlessPages: textless,
                removedHeaderFooterLines: output.removedHeaderFooterLines,
                paragraphs: output.paragraphs
            )
            model.structure = structure
            model.pipelineState = .ready
            model.readerBridge?.updateDebugAnnotations(structure: model.structure, show: model.debugShowBlocks)
            // Store (SPEC §8, M3): saves blocks/contents/Exhibits and
            // republishes documentRecord/analysis, off the critical path of
            // the first page (shown a while ago by this point).
            model.attachStructureToStore(structure)
        }
    }

    /// Working order per SPEC §7.1: first the pages visible at launch, then
    /// the others. `Task.yield()` every `batchSize` pages because the
    /// extraction stays on the MainActor (PDFKit is not `Sendable`) and must
    /// not block the interface (SPEC §9). `internal` because the integration
    /// tests on the real PDFs must go through the same batched path as the
    /// app, not a copy of the old loop that would keep a single
    /// `PDFDocument` warm.
    static func extractInBatches(
        sourceData: Data,
        fallbackDocument: PDFDocument,
        pageCount: Int,
        prioritizedPageRange: ClosedRange<Int>,
        progress: ((Double) -> Void)? = nil
    ) async -> [PageLayout] {
        await extractBatches(
            sourceData: sourceData,
            fallbackDocument: fallbackDocument,
            pageCount: pageCount,
            prioritizedPageRange: prioritizedPageRange,
            capturesPageTexts: false,
            progress: progress
        ).layouts
    }

    struct BatchedExtraction {
        let layouts: [PageLayout]
        let pageTexts: [String]
    }

    static func extractInBatchesWithPageTexts(
        sourceData: Data,
        fallbackDocument: PDFDocument,
        pageCount: Int,
        prioritizedPageRange: ClosedRange<Int>,
        progress: ((Double) -> Void)? = nil
    ) async -> BatchedExtraction {
        await extractBatches(
            sourceData: sourceData,
            fallbackDocument: fallbackDocument,
            pageCount: pageCount,
            prioritizedPageRange: prioritizedPageRange,
            capturesPageTexts: true,
            progress: progress
        )
    }

    private static func extractBatches(
        sourceData: Data,
        fallbackDocument: PDFDocument,
        pageCount: Int,
        prioritizedPageRange: ClosedRange<Int>,
        capturesPageTexts: Bool,
        progress: ((Double) -> Void)?
    ) async -> BatchedExtraction {
        var layouts = [PageLayout?](repeating: nil, count: pageCount)
        var pageTexts = capturesPageTexts ? [String?](repeating: nil, count: pageCount) : []
        let clampedVisible = prioritizedPageRange.clamped(to: 0 ... (pageCount - 1))
        var order = Array(clampedVisible)
        let visibleSet = Set(order)
        order.append(contentsOf: (0 ..< pageCount).filter { !visibleSet.contains($0) })

        var processedCount = 0
        for batchStart in stride(from: 0, to: order.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, order.count)
            let pageIndices = Array(order[batchStart ..< batchEnd])
            let extracted: [(Int, PageLayout, String?)] = autoreleasepool {
                let batchDocument = PDFDocument(data: sourceData)
                let document = batchDocument ?? fallbackDocument

                // As for the fingerprint, it keeps the M5b warm-up pass before
                // handing text and indices over to `LineExtractor`.
                for pageIndex in pageIndices {
                    _ = document.page(at: pageIndex)?.string
                }
                return pageIndices.compactMap { pageIndex in
                    guard let page = document.page(at: pageIndex) else { return nil }
                    let extracted = LineExtractor.extractWithText(page: page, pageIndex: pageIndex)
                    return (pageIndex, extracted.layout, capturesPageTexts ? extracted.pageText : nil)
                }
            }

            for (pageIndex, layout, pageText) in extracted {
                layouts[pageIndex] = layout
                if capturesPageTexts {
                    pageTexts[pageIndex] = pageText ?? ""
                }
            }
            processedCount += pageIndices.count
            progress?(Double(processedCount) / Double(pageCount))
            await Task.yield()
        }
        return BatchedExtraction(
            layouts: layouts.enumerated().map {
                $0.element ?? PageLayout(pageIndex: $0.offset, pageRect: .zero, lines: [], stringLength: 0)
            },
            pageTexts: capturesPageTexts ? pageTexts.map { $0 ?? "" } : []
        )
    }
}
