import Testing
import Foundation
@preconcurrency import PDFKit
@testable import LelePdf

/// Resident memory of the CURRENT PROCESS (`mach_task_basic_info`, not the
/// external `footprint`/`vmmap` tools): used only to compare before/after
/// within the same test process. It is not the same measure as
/// `scripts/measure-memory.sh`, which covers the whole app (PDFKit, SwiftUI,
/// thumbnails, Store).
enum ProcessMemory {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    /// PHYSICAL footprint of the process (`task_vm_info.phys_footprint`: the MEM
    /// column of `top`/Activity Monitor, including compressed or swapped-out
    /// pages). This, not RSS, is what reveals a runaway process: with a 38 GB
    /// footprint the RSS was 16 MB (`scripts/memory-watchdog.sh`).
    /// Thread-safe: just a `task_info` call.
    nonisolated static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}

/// Regression guard for the memory use of the text pipeline (SPEC §9) on a
/// synthetic 600-page PDF (`scripts/make-synthetic-pdf.swift`, never
/// committed, built here directly with PDFKit from the already staged pages of
/// the Draghi/Merck test PDFs; the real PDFs are never modified). It
/// exercises the same path as the app: fingerprinting and extraction through
/// ephemeral `PDFDocument`s in batches, while a separate document stays alive
/// like the `PDFView`'s one. Slow: skipped by default like the
/// `LELEPDF_REAL_CLAUDE` suites (same pattern: `ProcessInfo`, "skipping"
/// message), and not part of the ordinary `scripts/test.sh` run. To run it:
/// `LELEPDF_MEASURE_MEMORY=1 scripts/test.sh` (or `xcodebuild test` with the
/// same variable).
///
/// It measures the RSS growth of fingerprinting + extraction +
/// `TextPipeline.process`, not the footprint of the whole app: that is
/// measured live with `scripts/measure-memory.sh` (SPEC §9, 400 MB total budget
/// for the app). This threshold remains a loose internal guard, not the SPEC
/// budget.
extension HeavyTestSuites {
@Suite("Pipeline · memory budget (SPEC §9)")
struct MemoryBudgetTests {
    /// The four final runs of the combined path grew by 34, 44, 10, and 63 MB.
    /// 120 MB leaves almost double the worst case observed but fails if the
    /// earlier profile (~221 MB on average) comes back: it is a real guard, not
    /// the old 350 MB limit, which would have let the known regression pass.
    static let internalGuardBytes: UInt64 = 120_000_000

    @MainActor
    @Test("the monolithic cache stays excluded for long documents")
    func longDocumentsBypassMonolithicLayoutCache() {
        #expect(PipelineRunner.shouldUseLayoutCache(pageCount: 200))
        #expect(!PipelineRunner.shouldUseLayoutCache(pageCount: 201))
        #expect(!PipelineRunner.shouldUseLayoutCache(pageCount: 600))
    }

    @MainActor
    @Test("fingerprint + batched extraction + pipeline on 600 pages stay under the internal guard")
    func syntheticSixHundredPagesPipelineGrowthStaysUnderGuard() async throws {
        guard ProcessInfo.processInfo.environment["LELEPDF_MEASURE_MEMORY"] == "1" else {
            print("MemoryBudgetTests: skipping (LELEPDF_MEASURE_MEMORY is not \"1\"): slow measurement, not in the ordinary scripts/test.sh suite; to run it: LELEPDF_MEASURE_MEMORY=1 scripts/test.sh")
            return
        }
        guard TestPDFs.ensureAvailable(TestPDFs.draghi), TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: test PDFs not found")
            return
        }
        let targetPages = 600
        let syntheticData = try #require(autoreleasepool { () -> Data? in
            guard let a = PDFDocument(url: TestPDFs.draghi), let b = PDFDocument(url: TestPDFs.merck) else {
                return nil
            }
            let sources = [a, b]
            let synthetic = PDFDocument()
            var sourceIndex = 0
            while synthetic.pageCount < targetPages {
                let source = sources[sourceIndex % sources.count]
                for i in 0 ..< source.pageCount {
                    guard synthetic.pageCount < targetPages, let page = source.page(at: i) else { break }
                    synthetic.insert(page, at: synthetic.pageCount)
                }
                sourceIndex += 1
            }
            return synthetic.dataRepresentation()
        })
        let displayDocument = try #require(PDFDocument(data: syntheticData))
        let pageCount = displayDocument.pageCount

        let baseline = ProcessMemory.residentBytes()

        let extracted = await PipelineRunner.extractInBatchesWithPageTexts(
            sourceData: syntheticData,
            fallbackDocument: displayDocument,
            pageCount: pageCount,
            prioritizedPageRange: 0 ... 0
        )
        let fingerprint = DocumentFingerprint.compute(pageCount: pageCount, pageTexts: extracted.pageTexts)
        var layouts = extracted.layouts

        let output = await TextPipeline().process(layouts: layouts)
        layouts = []

        let after = ProcessMemory.residentBytes()
        let growth = after > baseline ? after - baseline : 0
        print("MEASURE batched pipeline memory (\(pageCount) synthetic pages, fingerprint \(fingerprint.prefix(8)), \(output.blocks.count) blocks): baseline \(baseline / 1_000_000) MB, after fingerprint+extraction+process \(after / 1_000_000) MB, growth \(growth / 1_000_000) MB; internal guard \(Self.internalGuardBytes / 1_000_000) MB")

        #expect(growth < Self.internalGuardBytes)
        withExtendedLifetime((syntheticData, displayDocument, output)) {}
    }
}
}
