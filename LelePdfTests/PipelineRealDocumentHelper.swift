import Foundation
@preconcurrency import PDFKit
@testable import LelePdf

/// Runs the extraction (MainActor) and the pure pipeline on a real
/// `PDFDocument`, for the integration tests (SPEC §11 row M2). Same sequence
/// as `PipelineRunner`, without the cache but with the SAME batched extractor
/// as the app: besides the full pipeline time, the tests on real PDFs thus
/// also cover the path that isolates PDFKit's per-page caches.
@MainActor
enum PipelineRealDocumentHelper {
    struct Result {
        let layouts: [PageLayout]
        let output: TextPipeline.Output
        let elapsed: TimeInterval
    }

    static func run(_ document: PDFDocument) async -> Result {
        let start = Date()
        let sourceData = document.dataRepresentation() ?? Data()
        let layouts = await PipelineRunner.extractInBatches(
            sourceData: sourceData,
            fallbackDocument: document,
            pageCount: document.pageCount,
            prioritizedPageRange: 0 ... max(0, document.pageCount - 1)
        )
        let output = await TextPipeline().process(layouts: layouts)
        let elapsed = Date().timeIntervalSince(start)
        return Result(layouts: layouts, output: output, elapsed: elapsed)
    }
}
