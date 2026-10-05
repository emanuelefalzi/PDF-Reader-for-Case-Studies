import Foundation
import AppKit
@preconcurrency import PDFKit
@testable import LelePdf

/// The `align` scenario of the F5 benchmark (F6-ALL): scrolls the PDF in
/// small steps (down and up), then in long jumps, then scrolls the panel (the
/// other direction of SPEC §5.8 "both sides can lead"), and at every step
/// records the window offset between the paragraph at the reading line and
/// its card (`PerfBenchAlignmentProbe`). Reports median, p90 and max per
/// group: steps, steps that cross a block boundary, right after a jump, after
/// settling, steps in which cards went from estimated to measured, panel
/// leading.
@MainActor
extension PerfBenchScenarios {
    private static let stepPt: CGFloat = 60
    /// Steps per phase (down, up, panel leading); `LELEPDF_BENCH_ALIGN_STEPS`
    /// reduces it for a short, bounded run (memory regression test, small
    /// reproductions).
    static var alignmentMaxStepsDefault: Int {
        Int(ProcessInfo.processInfo.environment["LELEPDF_BENCH_ALIGN_STEPS"] ?? "") ?? 700
    }
    private static let memoryLogEnabled = ProcessInfo.processInfo.environment["LELEPDF_BENCH_MEMLOG"] == "1"

    /// Per-step memory diagnostics (`LELEPDF_BENCH_MEMLOG=1`): footprint,
    /// bitmaps cached in the host, live text views, built rectangles, lazy
    /// window, counters of the coordinator and of the probe.
    private func memoryLog(_ kind: String, index: Int) {
        guard Self.memoryLogEnabled else { return }
        let geometry = model.rewritePanelGeometry
        let bitmaps = host.bitmapCacheStats
        let probe = PerfProbe.snapshot()
        func n(_ key: String) -> Int { probe[key]?.count ?? 0 }
        let footprint = PerfBenchMemoryGuard.footprintMB()
        let sync = model.syncCoordinator
        print(String(format: "[mem] %4d %@ footprint=%.0f MB (+%.0f) bitmaps=%d/%.0f MB textViews=%d realizedFrames=%d window=%d..<%d comp=%d publ=%d seg=%d build=%d redrive=%d (budget %d, exhausted %d) drive=%d stack=%d",
                     index, kind, footprint, footprint - host.memoryGuard.startMB, bitmaps.count, bitmaps.megabytes, host.textViewCount(), geometry.realizedFrames.count,
                     geometry.realizedRange.lowerBound, geometry.realizedRange.upperBound, geometry.compensationCount, geometry.publishedFramesCount,
                     sync.segments.count, n("sync.alignment.build"), sync.automaticRedriveCount, sync.automaticRedriveBudget, sync.automaticRedriveBudgetExhaustedCount, n("sync.drive"), n("swiftui.RewriteRowStack.body")))
    }

    /// Settling frames: lets the lazy window's growth steps (`asyncAfter`
    /// 1 ms) and the publication of the rectangles (`DispatchQueue.main.async`)
    /// go through.
    private func settle(frames: Int) async throws {
        for _ in 0 ..< frames {
            try await Task.sleep(for: .milliseconds(3))
            try finishFrame()
        }
    }

    func alignment(maxSteps: Int = PerfBenchScenarios.alignmentMaxStepsDefault) async throws {
        guard let pdfScroll = host.pdfScrollView, let panelScroll = host.panelScrollView else { return }
        let probe = PerfBenchAlignmentProbe(host: host, blocks: built.structure.blocks)
        var samples: [PerfBenchAlignmentProbe.Sample] = []
        var gapSteps = 0
        let geometry = model.rewritePanelGeometry
        let compensationsBefore = geometry.compensationCount
        let absorbedBefore = geometry.absorbedPoints
        let redrivesBefore = model.syncCoordinator.automaticRedriveCount
        let exhaustedBefore = model.syncCoordinator.automaticRedriveBudgetExhaustedCount

        // Region: the pages with analyzed blocks plus two (placeholders).
        let analyzedPages = built.analysis.blocks.keys.compactMap { id in built.structure.blocks.first { $0.id == id }?.pageEnd }
        let lastPage = min(model.pageCount - 1, (analyzedPages.max() ?? 0) + 2)
        guard let bridge = model.readerBridge, let endSpan = bridge.topDownPageSpan(pageIndex: lastPage) else { return }
        let regionEnd = min(endSpan.bottom, DocumentSpace.maxScrollTopDown(pdfScroll))

        @discardableResult
        func record(_ kind: String, previous: inout String?, measuredBefore: Set<String>) -> Int? {
            host.memoryGuardStep = "align · \(kind) · step \(samples.count + gapSteps + 1)"
            memoryLog(kind, index: samples.count + gapSteps + 1)
            if let sample = probe.sample(kind: kind, previousRowId: previous, measuredBefore: measuredBefore) {
                samples.append(sample)
                previous = sample.rowId
                return samples.count - 1
            }
            gapSteps += 1
            return nil
        }
        /// After settling: how many cards went from estimated to measured over
        /// the whole step (frame + settling), on both samples of the step.
        func noteFlips(_ indices: [Int?], measuredBefore: Set<String>) {
            let flips = probe.measuredRowIds.subtracting(measuredBefore).count
            for case let index? in indices { samples[index].flippedRows = flips }
        }

        // 1. Steps down, then up (going back up, rows ABOVE the visible part
        //    get measured: absorption/compensation).
        model.followPDF = true
        DocumentSpace.scroll(pdfScroll, topDownTop: 0)
        try await settle(frames: 6)
        var previous: String?
        var top: CGFloat = 0
        var steps = 0
        while top < regionEnd, steps < maxSteps {
            top += Self.stepPt
            steps += 1
            let measuredBefore = probe.measuredRowIds
            DocumentSpace.scroll(pdfScroll, topDownTop: top)
            try finishFrame()
            let first = record("step down", previous: &previous, measuredBefore: measuredBefore)
            try await settle(frames: 2)
            let second = record("step down · settled", previous: &previous, measuredBefore: measuredBefore)
            noteFlips([first, second], measuredBefore: measuredBefore)
        }
        steps = 0
        while top > 0, steps < maxSteps {
            top = max(0, top - Self.stepPt * 1.5)
            steps += 1
            let measuredBefore = probe.measuredRowIds
            DocumentSpace.scroll(pdfScroll, topDownTop: top)
            try finishFrame()
            let first = record("step up", previous: &previous, measuredBefore: measuredBefore)
            try await settle(frames: 2)
            let second = record("step up · settled", previous: &previous, measuredBefore: measuredBefore)
            noteFlips([first, second], measuredBefore: measuredBefore)
        }

        // 2. Long jumps (pages and headings from the contents), forward and back.
        let pages = model.pageCount
        // With few steps (short run), few jumps too.
        let jumpCount = maxSteps >= 700 ? Int.max : max(2, maxSteps / 10)
        let jumpPages = [11, 2, 16, 5, 9, 0, 13, 3, 7, 1].map { min($0, pages - 1) }.prefix(jumpCount)
        for page in jumpPages {
            let measuredBefore = probe.measuredRowIds
            model.goToPage(page)
            try finishFrame()
            let first = record("page jump · 1 frame", previous: &previous, measuredBefore: measuredBefore)
            try await settle(frames: 1)
            let second = record("page jump · 2 frames", previous: &previous, measuredBefore: measuredBefore)
            try await settle(frames: 5)
            let third = record("page jump · settled", previous: &previous, measuredBefore: measuredBefore)
            noteFlips([first, second, third], measuredBefore: measuredBefore)
            // Diagnostics: an explicit `drive` now; if the offset disappears,
            // the one at the time of the jump read a state not yet settled.
            model.syncCoordinator.followAfterNavigation(side: .pdf)
            try finishFrame()
            record("page jump · after an explicit drive (diagnostic)", previous: &previous, measuredBefore: measuredBefore)
            // After every jump: a scroll step, where the old model (rectangles
            // published one turn later) shows.
            let measured2 = probe.measuredRowIds
            if let (currentTop, _) = DocumentSpace.visibleTopDown(pdfScroll) {
                DocumentSpace.scroll(pdfScroll, topDownTop: currentTop + Self.stepPt)
            }
            try finishFrame()
            record("step after a jump", previous: &previous, measuredBefore: measured2)
            try await settle(frames: 2)
        }
        for entry in built.tocEntries.prefix(min(12, jumpCount)) {
            let measuredBefore = probe.measuredRowIds
            model.goToTocEntry(entry)
            try finishFrame()
            let first = record("jump to a heading · 1 frame", previous: &previous, measuredBefore: measuredBefore)
            try await settle(frames: 5)
            let second = record("jump to a heading · settled", previous: &previous, measuredBefore: measuredBefore)
            noteFlips([first, second], measuredBefore: measuredBefore)
        }

        // 3. The panel leads (SPEC "both sides can lead").
        DocumentSpace.scroll(panelScroll, topDownTop: 0)
        try await settle(frames: 6)
        var panelTop: CGFloat = 0
        let panelEnd = DocumentSpace.maxScrollTopDown(panelScroll)
        steps = 0
        while panelTop < panelEnd, steps < maxSteps {
            panelTop += Self.stepPt
            steps += 1
            let measuredBefore = probe.measuredRowIds
            DocumentSpace.scroll(panelScroll, topDownTop: panelTop)
            try finishFrame()
            let first = record("panel leads · step down", previous: &previous, measuredBefore: measuredBefore)
            try await settle(frames: 2)
            let second = record("panel leads · settled", previous: &previous, measuredBefore: measuredBefore)
            noteFlips([first, second], measuredBefore: measuredBefore)
        }

        DocumentSpace.scroll(pdfScroll, topDownTop: 0)
        try await settle(frames: 4)

        // AppKit/SwiftUI cross-check on the card at the reading line.
        var textOffsets: [Double] = []
        for sample in samples.suffix(40) where sample.realized {
            let blockId = String(sample.rowId.dropFirst(2))
            if let offset = probe.textViewsOffset(rowId: sample.rowId, blockId: blockId) { textOffsets.append(Double(offset)) }
        }

        report.section("PDF ↔ panel alignment (F6-ALL): offset in points at the reading line", Self.alignmentMarkdown(
            samples: samples, gapSteps: gapSteps, probe: probe,
            compensations: geometry.compensationCount - compensationsBefore,
            absorbed: geometry.absorbedPoints - absorbedBefore, textOffsets: textOffsets
        ) + "- Automatic `drive`s (after rebuilds/frame changes): \(model.syncCoordinator.automaticRedriveCount - redrivesBefore); per-gesture budget exhausted \(model.syncCoordinator.automaticRedriveBudgetExhaustedCount - exhaustedBefore) times.\n" + "\nDiagnostics: " + probe.clipRects() + "\n\n" + Self.worstDiagnostics(samples) + "\n" + probe.blocksTable())
    }

    /// The first samples and the worst ones (a single block at the line), with
    /// the diagnostics line recorded at the time of the sample.
    private static func worstDiagnostics(_ samples: [PerfBenchAlignmentProbe.Sample]) -> String {
        let steps = samples.filter { !$0.kind.contains("settled") }
        let first = steps.prefix(6)
        let worst = steps.filter { $0.overlapping == 1 }.sorted { abs($0.windowErrorPt) > abs($1.windowErrorPt) }.prefix(14)
        let worstAmbiguous = steps.filter { $0.overlapping > 1 }.sorted { abs($0.windowErrorPt) > abs($1.windowErrorPt) }.prefix(4)
        return (Array(first) + Array(worst) + Array(worstAmbiguous)).map { "- \($0.kind): \($0.diagnostics)" }.joined(separator: "\n") + "\n"
    }

    private static func alignmentMarkdown(samples: [PerfBenchAlignmentProbe.Sample], gapSteps: Int, probe: PerfBenchAlignmentProbe, compensations: Int, absorbed: CGFloat, textOffsets: [Double]) -> String {
        var out = ""
        if let offset = probe.readingLineOffset() {
            out += "- Panel reading line − PDF reading line, in window coordinates: **\(String(format: "%.1f", offset)) pt** (SPEC: 30% of the visible height of each side; the two sides have different headers).\n"
        }
        out += "- Samples: \(samples.count) (plus \(gapSteps) steps with the reading line outside every block: gaps, headings, figures; excluded).\n"
        out += "- Compensating scrolls (`compensateScroll`): \(compensations); points absorbed by the estimates: \(String(format: "%.0f", absorbed)).\n"
        if !textOffsets.isEmpty {
            let stats = PerfBenchStats(samplesMs: textOffsets)
            out += "- Cross-check (top of `MarkedNSTextView` − top of the real card): min \(String(format: "%.1f", stats.min)), max \(String(format: "%.1f", stats.max)) pt over \(stats.count) cards (constant = the real rectangle is AppKit's).\n"
        }
        out += "\n**Window offset** (card point − PDF reading line; positive = card lower):\n\n"
        out += PerfBenchAlignmentStats.header
        let kinds = ["step down", "step down · settled", "step up", "step up · settled", "page jump · 1 frame", "page jump · 2 frames", "page jump · settled", "page jump · after an explicit drive (diagnostic)", "step after a jump", "jump to a heading · 1 frame", "jump to a heading · settled", "panel leads · step down", "panel leads · settled"]
        for kind in kinds {
            out += PerfBenchAlignmentStats.row(kind, samples.filter { $0.kind == kind }.map(\.windowErrorPt))
        }
        let allSteps = samples.filter { ($0.kind.hasPrefix("step") || $0.kind.hasPrefix("panel")) && !$0.kind.contains("settled") }
        let steps = allSteps.filter { $0.overlapping == 1 }
        out += PerfBenchAlignmentStats.row("steps with several blocks overlapping the line (excluded from the groups below)", allSteps.filter { $0.overlapping > 1 }.map(\.windowErrorPt), note: "ambiguous paragraph")
        out += PerfBenchAlignmentStats.row("steps led by the PDF (a single block at the line)", steps.filter { $0.kind.hasPrefix("step") }.map(\.windowErrorPt))
        out += PerfBenchAlignmentStats.row("steps led by the panel (a single block at the line)", steps.filter { $0.kind.hasPrefix("panel") }.map(\.windowErrorPt))
        out += PerfBenchAlignmentStats.row("steps that cross a block boundary", steps.filter(\.boundary).map(\.windowErrorPt))
        out += PerfBenchAlignmentStats.row("steps within the same block", steps.filter { !$0.boundary }.map(\.windowErrorPt))
        out += PerfBenchAlignmentStats.row("steps with cards that went from estimated to measured", steps.filter { $0.flippedRows > 0 }.map(\.windowErrorPt), note: "\(steps.filter { $0.flippedRows > 0 }.reduce(0) { $0 + $1.flippedRows }) cards in total")
        out += PerfBenchAlignmentStats.row("steps with the target card still estimated before the step", steps.filter { !$0.measuredBefore }.map(\.windowErrorPt))
        out += PerfBenchAlignmentStats.row("steps with the target card not built after the step", steps.filter { !$0.realized }.map(\.windowErrorPt))
        for (lo, hi) in [(0.0, 0.25), (0.25, 0.5), (0.5, 0.75), (0.75, 1.01)] {
            out += PerfBenchAlignmentStats.row("steps with fraction within the paragraph in [\(lo), \(hi))", steps.filter { $0.fraction >= lo && $0.fraction < hi }.map(\.windowErrorPt))
        }
        out += "\n**SPEC offset** (against the panel's own reading line) and **stale rectangles** (true top − top in the model):\n\n"
        out += PerfBenchAlignmentStats.header
        out += PerfBenchAlignmentStats.row("SPEC · steps", steps.map(\.specErrorPt))
        out += PerfBenchAlignmentStats.row("SPEC · jumps (1 frame)", samples.filter { $0.kind.hasSuffix("1 frame") }.map(\.specErrorPt))
        out += PerfBenchAlignmentStats.row("SPEC · panel leads", samples.filter { $0.kind.hasPrefix("panel") && !$0.kind.contains("settled") }.map(\.specErrorPt))
        out += PerfBenchAlignmentStats.row("stale rectangles · steps", steps.map(\.staleFramePt))
        out += PerfBenchAlignmentStats.row("stale rectangles · jumps (1 frame)", samples.filter { $0.kind.hasSuffix("1 frame") }.map(\.staleFramePt))
        out += PerfBenchAlignmentStats.row("stale rectangles · settled", samples.filter { $0.kind.contains("settled") }.map(\.staleFramePt))
        let worst = steps.sorted { abs($0.windowErrorPt) > abs($1.windowErrorPt) }.prefix(8)
        out += "\nWorst steps: " + worst.map { "\($0.kind) \($0.rowId) f=\(String(format: "%.2f", $0.fraction)) err=\(String(format: "%.0f", $0.windowErrorPt))\($0.boundary ? " boundary" : "")" }.joined(separator: "; ") + "\n"
        return out
    }
}
