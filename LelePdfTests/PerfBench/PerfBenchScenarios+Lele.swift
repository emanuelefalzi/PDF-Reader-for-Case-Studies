import Foundation
import AppKit
import SwiftUI
@preconcurrency import PDFKit
@testable import LelePdf

/// The four concrete symptoms the author reported after trying F4, measured
/// first:
/// 1. everything slows down while Claude writes the summary;
/// 2. scrolling is heavy only on pages with marks, even with "Follow the
///    PDF" off;
/// 3. selecting text is smooth in the analyzed section, slow elsewhere;
/// 4. dragging the panel divider is slow.
@MainActor
extension PerfBenchScenarios {
    // MARK: - P-2 · scrolling on pages with and without marks, with "Follow the PDF" on and off

    func scrollMarkedVsUnmarked() async throws {
        guard let scrollView = host.pdfScrollView, let bridge = model.readerBridge else { return }
        let markedPages = Set(built.analysis.blocks.keys.compactMap { id in built.structure.blocks.first { $0.id == id }?.pageStart })
        guard let lastMarked = markedPages.max() else { return }
        let firstUnmarked = lastMarked + 1
        let regions: [(name: String, from: Int, to: Int)] = [
            ("WITH marks", markedPages.min() ?? 0, lastMarked),
            ("WITHOUT marks", firstUnmarked, model.pageCount - 1),
        ]
        let originalFollow = model.followPDF
        for region in regions where region.from <= region.to {
            guard let startSpan = bridge.topDownPageSpan(pageIndex: region.from), let endSpan = bridge.topDownPageSpan(pageIndex: region.to) else { continue }
            for follow in [true, false] {
                model.followPDF = follow
                var top = startSpan.top
                var frames: [PerfBenchHost.FrameCost] = []
                let outcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
                    top = top + 60 > endSpan.bottom - 200 ? startSpan.top : top + 60
                    DocumentSpace.scroll(scrollView, topDownTop: top)
                    frames.append(try finishFrame())
                }
                frames = Array(frames.suffix(config.reps))
                addSplit("P-2 scroll on pages \(region.name) · Follow the PDF \(follow ? "on" : "off")", outcome: outcome, frames: frames, note: "pages \(region.from + 1)-\(region.to + 1), 60 pt ticks")
            }
        }
        model.followPDF = originalFollow
        DocumentSpace.scroll(scrollView, topDownTop: 0)
        try finishFrame()
    }

    // MARK: - P-4 · dragging the panels' divider

    func dividerDrag() async throws {
        let rightWidths: [CGFloat] = Array(stride(from: DSMetrics.rightPanelDefaultWidth, through: DSMetrics.rightPanelMaxWidth, by: 12))
            + Array(stride(from: DSMetrics.rightPanelMaxWidth, through: DSMetrics.rightPanelMinWidth, by: -12))
        var frames: [PerfBenchHost.FrameCost] = []
        var index = 0
        let outcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
            let width = rightWidths[index % rightWidths.count]
            index += 1
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.rightPanelWidth = width } // as in `PaneDivider.setWidth`
            frames.append(try finishFrame())
        }
        frames = Array(frames.suffix(config.reps))
        addSplit("P-4 right divider drag (one mouse event), WITHOUT freezing (reference)", outcome: outcome, frames: frames, note: "panel width 392→520→320 pt in 12 pt steps; the PDF re-fits (autoScales)")
        withTransaction(Transaction()) { model.rightPanelWidth = DSMetrics.rightPanelDefaultWidth }
        try finishFrame()

        // The same gesture as `PaneDivider` performs it after the fix:
        // `WindowResizeCoalescer.begin()` at the first event (panel frozen,
        // autoScales suspended), `end()` on release (a single real pass).
        frames = []
        index = 0
        model.windowResizeCoalescer.begin()
        try finishFrame()
        let frozenOutcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
            let width = rightWidths[index % rightWidths.count]
            index += 1
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.rightPanelWidth = width }
            frames.append(try finishFrame())
        }
        frames = Array(frames.suffix(config.reps))
        addSplit("P-4 right divider drag (one mouse event), WITH freezing", outcome: frozenOutcome, frames: frames, note: "same widths; `PaneDivider.onDragging` → `WindowResizeCoalescer.begin()`")
        PerfProbe.reset()
        let releaseStart = CFAbsoluteTimeGetCurrent()
        model.windowResizeCoalescer.end()
        try finishFrame()
        let releaseMs = (CFAbsoluteTimeGetCurrent() - releaseStart) * 1000
        report.add("P-4 right divider release (end of drag)", samplesMs: [releaseMs], note: "`end()`: panel re-wrapped at its final width, PDF re-fitted, alignment rebuilt, once per gesture", breakdown: PerfProbe.snapshot(reset: true))
        withTransaction(Transaction()) { model.rightPanelWidth = DSMetrics.rightPanelDefaultWidth }
        try finishFrame()

        let sidebarWidths: [CGFloat] = Array(stride(from: DSMetrics.sidebarWidth, through: DSMetrics.sidebarMaxWidth, by: 12))
            + Array(stride(from: DSMetrics.sidebarMaxWidth, through: DSMetrics.sidebarMinWidth, by: -12))
        frames = []
        index = 0
        let sidebarOutcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
            let width = sidebarWidths[index % sidebarWidths.count]
            index += 1
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.sidebarWidth = width }
            frames.append(try finishFrame())
        }
        frames = Array(frames.suffix(config.reps))
        addSplit("P-4 left divider drag (one mouse event)", outcome: sidebarOutcome, frames: frames, note: "sidebar 264→360→200 pt in 12 pt steps")
        withTransaction(Transaction()) { model.sidebarWidth = DSMetrics.sidebarWidth }
        try finishFrame()
    }

    // MARK: - P-3 · text selection inside and outside the analyzed section

    func textSelection() async throws {
        guard let pdfView = host.pdfView, let document = pdfView.document else { return }
        let markedPages = Set(built.analysis.blocks.keys.compactMap { id in built.structure.blocks.first { $0.id == id }?.pageStart })
        let warmPage = markedPages.min() ?? 0
        // "Cold" page: never touched by marks or by PDFKit (far from the
        // analyzed section), the last one with text.
        let lastMarked = markedPages.max() ?? -1
        let pagesWithBlocks = Set(built.structure.blocks.map(\.pageStart))
        let coldPage = (0 ..< model.pageCount).reversed().first { $0 > lastMarked && pagesWithBlocks.contains($0) } ?? model.pageCount - 1
        let originalPage = model.currentPageIndex

        // Cost of PDFKit alone: first text extraction of a cold page of the
        // DISPLAYED document (the pipeline no longer warms it up), then the
        // same call when warm.
        if let page = document.page(at: coldPage) {
            var start = CFAbsoluteTimeGetCurrent()
            _ = page.string
            let coldStringMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            start = CFAbsoluteTimeGetCurrent()
            _ = page.selection(for: NSRange(location: 0, length: 40))
            let coldSelectionMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            start = CFAbsoluteTimeGetCurrent()
            _ = page.selection(for: NSRange(location: 0, length: 40))
            let warmSelectionMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            report.fact("PDFKit, cold page \(coldPage + 1)", "first `page.string` \(String(format: "%.1f", coldStringMs)) ms · first `selection(for:)` \(String(format: "%.1f", coldSelectionMs)) ms · second \(String(format: "%.2f", warmSelectionMs)) ms")
        }

        for (label, pageIndex) in [("analyzed section (warm page \(warmPage + 1))", warmPage), ("outside the section (page \(coldPage + 1))", coldPage)] {
            guard let page = document.page(at: pageIndex) else { continue }
            model.goToPage(pageIndex)
            try finishFrame()
            try await host.pump(seconds: 0.1)
            let bounds = page.bounds(for: .mediaBox)
            let start = CGPoint(x: bounds.minX + 60, y: bounds.maxY - 120)
            var samples: [Double] = []
            var hoverSamples: [Double] = []
            var frames: [PerfBenchHost.FrameCost] = []
            let steps = 12
            // During the drag the button is pressed: the mini bar waits for
            // the mouse-up (`MarksOverlaySelectionBar`).
            host.marksOverlay?.isLeftMouseButtonPressed = { true }
            for rep in 0 ..< (config.reps + warmup) {
                let step = rep % steps
                let end = CGPoint(x: bounds.minX + 60 + CGFloat(step) * 30, y: bounds.maxY - 140 - CGFloat(step) * 14)
                let t0 = CFAbsoluteTimeGetCurrent()
                // What the PDFView does on every `mouseDragged` of a
                // selection: a new selection from the starting point to the mouse.
                if let selection = page.selection(from: start, to: end) {
                    pdfView.setCurrentSelection(selection, animate: false)
                }
                let frame = try finishFrame()
                let total = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                // And what AppKit asks the marks overlay for the same event:
                // `hitTest` (who receives the mouse?).
                let h0 = CFAbsoluteTimeGetCurrent()
                _ = host.marksOverlay?.hitTest(pdfView.convert(end, from: page))
                let hover = (CFAbsoluteTimeGetCurrent() - h0) * 1000
                if rep >= warmup { samples.append(total); hoverSamples.append(hover); frames.append(frame) }
                await Task.yield() // see `PerfBenchRunner.run`
            }
            report.add("P-3 text selection \(label): one drag event", samplesMs: samples, note: "`selection(from:to:)` + `setCurrentSelection` + frame; the mini bar waits for the mouse-up", breakdown: PerfProbe.snapshot(reset: true))
            report.add("P-3 selection \(label): overlay `hitTest` per event", samplesMs: hoverSamples, note: "who receives the mouse over the PDF", breakdown: [:])
            // The mouse-up: the bar is built ONCE on the final selection.
            host.marksOverlay?.isLeftMouseButtonPressed = { false }
            PerfProbe.reset()
            let upStart = CFAbsoluteTimeGetCurrent()
            host.marksOverlay?.handleSelectionBarMouseUp()
            try finishFrame()
            await Task.yield()
            try finishFrame()
            let upMs = (CFAbsoluteTimeGetCurrent() - upStart) * 1000
            report.add("P-3 selection \(label): mini bar on mouse-up (once per gesture)", samplesMs: [upMs], note: "`handleSelectionBarMouseUp` + frame: building the bar on the final selection", breakdown: PerfProbe.snapshot(reset: true))
            pdfView.clearSelection()
            try finishFrame()
        }
        model.goToPage(originalPage)
        try finishFrame()
    }

    // MARK: - P-1 · analysis in progress and arrival of an analysis

    func analysisRunning() async throws {
        guard let scrollView = host.pdfScrollView else { return }
        let unanalyzed = built.structure.blocks.filter { built.analysis.blocks[$0.id] == nil }.map(\.id)
        let targets = unanalyzed.isEmpty ? built.structure.blocks.suffix(4).map(\.id) : Array(unanalyzed.prefix(4))
        guard let runningTarget = targets.first else { return }

        // 1) A `claude` process that never ends (the fake CLI's `timeout`
        //    mode): scrolling while the analysis is "in progress".
        await setFakeClaude(mode: "timeout")
        do {
            model.analysisController.analyze(blockId: runningTarget)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, model.analysisController.queue.runningBlockId != runningTarget { try await Task.sleep(for: .milliseconds(10)) }
            try await host.pump(seconds: 0.4)
            var top: CGFloat = 0
            var frames: [PerfBenchHost.FrameCost] = []
            let maxTop = DocumentSpace.maxScrollTopDown(scrollView)
            let outcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
                top = top + 60 > maxTop ? 0 : top + 60
                DocumentSpace.scroll(scrollView, topDownTop: top)
                frames.append(try finishFrame())
            }
            frames = Array(frames.suffix(config.reps))
            addSplit("P-1 PDF scroll WHILE an analysis is in progress", outcome: outcome, frames: frames, note: "stuck fake CLI process; measures only the app's own work, not the CPU/RAM pressure of the real `claude`")

            // IDLE UI while the analysis is in progress: what does the app do
            // on its own? (the "Claude is analyzing…" placeholder has a 1 Hz
            // `TimelineView` counter: every tick re-evaluates the row and may
            // redo the layout of the whole panel). Three seconds of run loop
            // without any action, with the stall meter.
            let idleMeter = PerfBenchStallMeter()
            PerfProbe.reset()
            idleMeter.start()
            try await host.pump(seconds: 3.0)
            idleMeter.stop()
            let idleBreakdown = PerfProbe.snapshot(reset: true)
            report.add("P-1 analysis in progress, UI idle for 3 s: longest main-thread stall", samplesMs: [idleMeter.maxGapMs], note: "no user action; \(idleMeter.stallCount) gaps above 8 ms in 3 s (ticks of the placeholder's \"about N s\" counter)", breakdown: idleBreakdown)
            report.add("P-1 analysis in progress, UI idle for 3 s: total time with the UI stalled", samplesMs: [idleMeter.stalledMs], note: "sum of the gaps above the threshold in the 3 s", breakdown: [:])
            model.analysisController.cancel(blockId: runningTarget)
            let cancelDeadline = Date().addingTimeInterval(10)
            while Date() < cancelDeadline, model.analysisController.queue.runningBlockId != nil { try await Task.sleep(for: .milliseconds(20)) }
            DocumentSpace.scroll(scrollView, topDownTop: 0)
            try finishFrame()
        }

        // 2) Arrival of an analysis (fake CLI in `success` mode): the first
        //    frame after the save, with everything it invalidates (mark
        //    cache, repetitions, panel, alignment).
        var worstStall: [Double] = []
        var totalStalled: [Double] = []
        var breakdown: [String: PerfProbe.Entry] = [:]
        await setFakeClaude(mode: "success")
        do {
            let meter = PerfBenchStallMeter()
            for blockId in targets.dropFirst().prefix(3) {
                PerfProbe.reset()
                meter.start()
                model.analysisController.analyze(blockId: blockId)
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline, model.analysisController.blockState(blockId) != .analyzed { try await Task.sleep(for: .milliseconds(2)) }
                // The main-thread work on arrival (context replaced, caches
                // cleared, panel re-evaluated, alignment rebuilt) is consumed
                // in the run loop turns right after: let it finish and
                // measure the stalls.
                try await host.pump(seconds: 1.0)
                try finishFrame()
                meter.stop()
                worstStall.append(meter.maxGapMs)
                totalStalled.append(meter.stalledMs)
                merge(&breakdown, PerfProbe.snapshot(reset: true))
                try await host.pump(seconds: 0.3)
            }
        }
        await setFakeClaude(mode: nil)
        report.add("P-1 analysis arrival: longest main-thread stall", samplesMs: worstStall, note: "maximum gap between two 2 ms ticks while the analysis arrives and the panel updates (threshold 8 ms)", breakdown: breakdown)
        report.add("P-1 analysis arrival: total time with the UI stalled", samplesMs: totalStalled, note: "sum of the gaps above the threshold, from the start of the fake CLI to the panel being updated", breakdown: [:])
    }

    /// Fake CLI (staged by `scripts/test.sh`) in the desired mode, or
    /// restoration of the environment with `nil`; the same mechanism as
    /// `withClaudeTestEnv` (`ClaudeTestSupport.swift`) without passing a
    /// MainActor closure to a non-isolated function.
    private func setFakeClaude(mode: String?) async {
        if let mode {
            setenv("LELEPDF_CLAUDE_PATH", FakeClaudeLocator.path, 1)
            setenv("FAKE_CLAUDE_MODE", mode, 1)
        } else {
            unsetenv("LELEPDF_CLAUDE_PATH")
            unsetenv("FAKE_CLAUDE_MODE")
        }
        await ClaudeCLILocator.shared.resetCache()
    }
}
