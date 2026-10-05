import Foundation
import AppKit
@preconcurrency import PDFKit
@testable import LelePdf

/// The interactions measured by the F5 benchmark (see
/// `PerformanceBenchmarkTests`). Each scenario: a REAL action on the views
/// (the same calls AppKit/SwiftUI would make for the user's event) → one pass
/// of the run loop → layout → drawing of the dirty views; the sample is the
/// wall-clock time of the whole repetition, and `PerfProbe` says in which
/// stage it went.
@MainActor
struct PerfBenchScenarios {
    let host: PerfBenchHost
    let built: PerfBenchDocument.Built
    let config: HeavyTestSuites.PerformanceBenchmarkTests.Config
    let report: PerfBenchReport

    var model: DocumentModel { host.model }
    var warmup: Int { 3 }

    /// Closes the repetition as the app would: run loop, layout, drawing.
    /// Returns the layout and drawing costs separately (for the report's
    /// "logic only"/"drawing only" rows). Then the memory guard
    /// (`PerfBenchMemoryGuard`): every frame of the benchmark goes through
    /// here, so a runaway scenario fails within one step, with the numbers.
    @discardableResult
    func finishFrame() throws -> PerfBenchHost.FrameCost {
        HeavyTestSuites.PerformanceBenchmarkTests.spinOnce()
        let cost = host.frame()
        memoryLogFrame()
        try host.memoryGuard.check(step: host.memoryGuardStep)
        return cost
    }

    /// Per-frame diagnostics with `LELEPDF_BENCH_MEMLOG=1`, for ALL scenarios
    /// (previously only `align`, `PerfBenchScenarios+Alignment.swift`):
    /// footprint, growth since the start, bitmaps cached in the host and live
    /// text views; enough to see in which scenario/frame the guard
    /// (`PerfBenchMemoryGuard`) is about to trip.
    private static let frameMemoryLogEnabled = ProcessInfo.processInfo.environment["LELEPDF_BENCH_MEMLOG"] == "1"

    private func memoryLogFrame() {
        guard Self.frameMemoryLogEnabled else { return }
        let footprint = PerfBenchMemoryGuard.footprintMB()
        let bitmaps = host.bitmapCacheStats
        print(String(format: "[mem-frame] %4d %@ footprint=%.0f MB (+%.0f) bitmaps=%d/%.0f MB textViews=%d",
                     host.memoryGuard.checks + 1, host.memoryGuardStep.isEmpty ? "-" : host.memoryGuardStep,
                     footprint, footprint - host.memoryGuard.startMB, bitmaps.count, bitmaps.megabytes, host.textViewCount()))
    }

    /// Records four rows for a scroll/hover scenario: total, without
    /// drawing, layout only, drawing only, so it is immediately visible how
    /// much the rasterization of the overlays weighs compared with the logic.
    func addSplit(_ name: String, outcome: PerfBenchRunner.Outcome, frames: [PerfBenchHost.FrameCost], note: String) {
        report.add(name, samplesMs: outcome.samplesMs, note: note, breakdown: outcome.breakdown)
        let logic = zip(outcome.samplesMs, frames).map { $0 - $1.drawMs }
        report.add("\(name) · without drawing", samplesMs: logic, note: "logic + notifications + SwiftUI + layout", breakdown: [:])
        report.add("\(name) · layout only", samplesMs: frames.map(\.layoutMs), note: "the window's `layoutSubtreeIfNeeded()`: SwiftUI (bodies + `sizeThatFits`) and Auto Layout", breakdown: [:])
        report.add("\(name) · drawing only", samplesMs: frames.map(\.drawMs), note: "rasterization of dirty views (\(frames.last?.drawnViews ?? 0) views in the last rep.)", breakdown: [:])
    }

    // MARK: - Baseline

    func baseline() async throws {
        var frames: [PerfBenchHost.FrameCost] = []
        let outcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
            frames.append(try finishFrame())
        }
        report.add("empty frame (no action)", samplesMs: outcome.samplesMs, note: "fixed cost of run loop + layout + dirty check", breakdown: outcome.breakdown)
    }

    // MARK: - Scrolling

    func scrollPDF() async throws {
        guard let scrollView = host.pdfScrollView else { return }
        let step: CGFloat = 60
        let maxTop = DocumentSpace.maxScrollTopDown(scrollView)
        var top: CGFloat = 0
        var frames: [PerfBenchHost.FrameCost] = []
        let outcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
            top = top + step > maxTop ? 0 : top + step
            DocumentSpace.scroll(scrollView, topDownTop: top)
            frames.append(try finishFrame())
        }
        frames = Array(frames.suffix(config.reps))
        addSplit("PDF scroll (one \(Int(step)) pt tick)", outcome: outcome, frames: frames, note: "\"Follow the PDF\" on: also drags the right panel")
        DocumentSpace.scroll(scrollView, topDownTop: 0)
        try finishFrame()
    }

    func scrollPanel() async throws {
        guard let scrollView = host.panelScrollView else { return }
        let step: CGFloat = 60
        let maxTop = DocumentSpace.maxScrollTopDown(scrollView)
        var top: CGFloat = 0
        var frames: [PerfBenchHost.FrameCost] = []
        let outcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
            top = top + step > maxTop ? 0 : top + step
            DocumentSpace.scroll(scrollView, topDownTop: top)
            frames.append(try finishFrame())
        }
        frames = Array(frames.suffix(config.reps))
        addSplit("right panel scroll (one \(Int(step)) pt tick)", outcome: outcome, frames: frames, note: "drags the PDF (and its overlays) along")
        DocumentSpace.scroll(scrollView, topDownTop: 0)
        if let pdf = host.pdfScrollView { DocumentSpace.scroll(pdf, topDownTop: 0) }
        try finishFrame()
    }

    // MARK: - Hover

    /// Points (overlay space) at the center of the visible marks, alternated
    /// with a point just outside the mark: the mouse crossing marked words.
    private func hoverPoints() -> [CGPoint] {
        guard let overlay = host.marksOverlay else { return [] }
        var points: [CGPoint] = []
        for page in model.visiblePageRange {
            for entry in overlay.hitItems(forPage: page) {
                guard let rect = entry.rects.first, overlay.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
                points.append(CGPoint(x: rect.midX, y: rect.midY))
                points.append(CGPoint(x: rect.minX - 6, y: rect.maxY + 6))
            }
        }
        return points
    }

    func hoverPDF() async throws {
        guard let overlay = host.marksOverlay else { return }
        try finishFrame()
        let points = hoverPoints()
        guard !points.isEmpty else { report.fact("hover PDF", "no visible mark on the first page: scenario skipped"); return }
        var frames: [PerfBenchHost.FrameCost] = []
        var index = 0
        let outcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
            overlay.handleMouseMoved(at: points[index % points.count])
            index += 1
            frames.append(try finishFrame())
        }
        frames = Array(frames.suffix(config.reps))
        addSplit("hover on the PDF (mouse from one mark to another)", outcome: outcome, frames: frames, note: "\(points.count / 2) visible marks; each repetition enters or leaves a mark")
        overlay.clearHover()
        try finishFrame()
    }

    /// Panel side: what `MarkedNSTextView.mouseMoved` and
    /// `BlockCardView.onHover` do to the model when the mouse passes over the
    /// terms of a card.
    func hoverPanel() async throws {
        let targets: [(blockId: String, mark: Mark)] = built.structure.blocks.compactMap { block in
            guard let analysis = built.analysis.blocks[block.id], let mark = analysis.marks.first else { return nil }
            return (block.id, mark)
        }
        guard !targets.isEmpty else { return }
        var frames: [PerfBenchHost.FrameCost] = []
        var index = 0
        let outcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
            let target = targets[index % targets.count]
            if index % 2 == 0 {
                model.setHoveredBlock(target.blockId)
                model.setHover(termId: target.mark.termId, markId: target.mark.id, blockId: target.blockId)
            } else {
                model.setHover(termId: nil)
                model.setHoveredBlock(nil)
            }
            index += 1
            frames.append(try finishFrame())
        }
        frames = Array(frames.suffix(config.reps))
        addSplit("hover on the right panel (term + card)", outcome: outcome, frames: frames, note: "enters/leaves a marked term of a card; lights up its counterpart in the PDF")
        model.setHover(termId: nil)
        model.setHoveredBlock(nil)
        try finishFrame()
    }

    /// Only the "focused" block: the mouse moving down from one paragraph of
    /// the PDF to the next without touching marks.
    func hoverBlocks() async throws {
        let ids = built.structure.blocks.prefix(6).map(\.id)
        guard ids.count >= 2 else { return }
        var frames: [PerfBenchHost.FrameCost] = []
        var index = 0
        let outcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
            model.setHoveredBlock(ids[index % ids.count])
            index += 1
            frames.append(try finishFrame())
        }
        frames = Array(frames.suffix(config.reps))
        addSplit("hover between PDF paragraphs (focused block)", outcome: outcome, frames: frames, note: "changes `hoveredBlockId`: margin bar + card accent")
        model.setHoveredBlock(nil)
        try finishFrame()
    }
}
