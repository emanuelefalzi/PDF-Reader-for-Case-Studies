import Foundation
import AppKit
@preconcurrency import PDFKit
@testable import LelePdf

/// Second half of the F5 benchmark scenarios (a separate file to keep files
/// short): manual marks, notes, zoom, page jump, sidebar, concept map,
/// opening/switching documents.
@MainActor
extension PerfBenchScenarios {
    // MARK: - Manual marks

    /// Adds and removes a manual mark on a visible block: the real path of
    /// `MarksOverlaySelectionBar.addManualMark`/`removeMark` (local context →
    /// cache → notifications → Store actor).
    func markAddRemove() async throws {
        let blockId = model.analysisController.readingPositionBlock(currentPageIndex: model.currentPageIndex)
            ?? built.structure.blocks.first?.id
        guard let blockId, let block = built.structure.blocks.first(where: { $0.id == blockId }) else { return }
        let words = block.cleanText.split(separator: " ").filter { $0.count >= 7 }.prefix(60)
        let reps = min(config.reps, 12)
        var addSamples: [Double] = []
        var removeSamples: [Double] = []
        var addBreakdown: [String: PerfProbe.Entry] = [:]
        var removeBreakdown: [String: PerfProbe.Entry] = [:]
        var wordIndex = 0
        for rep in 0 ..< (reps + warmup) {
            let word = String(words[wordIndex % max(1, words.count)])
            wordIndex += 1
            guard let range = block.cleanText.range(of: word) else { continue }
            let start = block.cleanText.distance(from: block.cleanText.startIndex, to: range.lowerBound)
            let measured = rep >= warmup
            if measured { PerfProbe.reset() }
            let addStart = CFAbsoluteTimeGetCurrent()
            await model.analysisController.addManualMark(blockId: blockId, type: .underline, text: word, page: block.pageStart, cleanRange: NSRange(location: start, length: word.count))
            host.marksOverlay?.invalidate()
            try finishFrame()
            let addMs = (CFAbsoluteTimeGetCurrent() - addStart) * 1000
            if measured { addSamples.append(addMs); merge(&addBreakdown, PerfProbe.snapshot(reset: true)) }

            guard let manual = model.analysisController.context?.analysis.blocks[blockId]?.marks.last(where: { $0.source == .manual }) else { continue }
            let removeStart = CFAbsoluteTimeGetCurrent()
            await model.analysisController.removeMark(blockId: blockId, markId: manual.id)
            host.marksOverlay?.invalidate()
            try finishFrame()
            let removeMs = (CFAbsoluteTimeGetCurrent() - removeStart) * 1000
            if measured { removeSamples.append(removeMs); merge(&removeBreakdown, PerfProbe.snapshot(reset: true)) }
        }
        report.add("adding a manual mark", samplesMs: addSamples, note: "block at the reading position; includes waiting for the Store actor", breakdown: addBreakdown)
        report.add("removing a manual mark", samplesMs: removeSamples, note: "same block", breakdown: removeBreakdown)
    }

    func merge(_ into: inout [String: PerfProbe.Entry], _ snapshot: [String: PerfProbe.Entry]) {
        for (label, entry) in snapshot {
            var current = into[label] ?? PerfProbe.Entry()
            current.count += entry.count
            current.totalMs += entry.totalMs
            current.maxMs = max(current.maxMs, entry.maxMs)
            into[label] = current
        }
    }

    // MARK: - Notes (free annotations)

    func note() async throws {
        let page = model.currentPageIndex
        let reps = min(config.reps, 12)
        var createSamples: [Double] = []
        var typeSamples: [Double] = []
        var deleteSamples: [Double] = []
        var breakdown: [String: PerfProbe.Entry] = [:]
        model.annotationController.barVisible = true
        model.annotationController.selectTool(.note)
        try finishFrame()
        for rep in 0 ..< (reps + warmup) {
            let measured = rep >= warmup
            if measured { PerfProbe.reset() }
            let point = CGPoint(x: 120 + Double(rep) * 3, y: 500)
            var start = CFAbsoluteTimeGetCurrent()
            let annotation = model.annotationController.createNote(page: page, at: point)
            try finishFrame()
            if measured { createSamples.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }

            start = CFAbsoluteTimeGetCurrent()
            model.annotationController.updateNoteText(id: annotation.id, text: "Appunto di prova numero \(rep)")
            try finishFrame()
            if measured { typeSamples.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }

            start = CFAbsoluteTimeGetCurrent()
            model.annotationController.delete(id: annotation.id)
            try finishFrame()
            if measured { deleteSamples.append((CFAbsoluteTimeGetCurrent() - start) * 1000); merge(&breakdown, PerfProbe.snapshot(reset: true)) }
        }
        model.annotationController.barVisible = false
        try finishFrame()
        report.add("note: creation (click with the Note tool)", samplesMs: createSamples, note: "`createNote` + PDFKit renderer + overlay", breakdown: breakdown)
        report.add("note: text saved when the popover closes", samplesMs: typeSamples, note: "`updateNoteText`; text typed in the popover does not touch the model on every keystroke", breakdown: [:])
        report.add("note: deletion", samplesMs: deleteSamples, note: "", breakdown: [:])
    }

    // MARK: - ⌃+wheel zoom

    func zoomBurst() async throws {
        guard let pdfView = host.pdfView else { return }
        let ticks = 20
        let scales = (0 ..< ticks).map { i in 1.0 + 0.04 * Double(i % 10 + 1) }
        var withGate: [Double] = []
        var withoutGate: [Double] = []
        var endSamples: [Double] = []
        var gateBreakdown: [String: PerfProbe.Entry] = [:]
        var noGateBreakdown: [String: PerfProbe.Entry] = [:]
        let originalAutoScales = pdfView.autoScales
        for pass in 0 ..< 2 {
            let gated = pass == 0
            for _ in 0 ..< 2 { // second pass measured, the first is warm-up
                PerfProbe.reset()
                var samples: [Double] = []
                if gated { model.syncCoordinator.beginZoomGesture() }
                for scale in scales {
                    let start = CFAbsoluteTimeGetCurrent()
                    pdfView.scaleFactor = scale // same call as `applyAnchoredZoom`
                    try finishFrame()
                    samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    await Task.yield() // see `PerfBenchRunner.run`
                }
                let endStart = CFAbsoluteTimeGetCurrent()
                if gated { model.syncCoordinator.endZoomGesture() }
                try finishFrame()
                let endMs = (CFAbsoluteTimeGetCurrent() - endStart) * 1000
                if gated { withGate = samples; endSamples = [endMs]; gateBreakdown = PerfProbe.snapshot(reset: true) }
                else { withoutGate = samples; noGateBreakdown = PerfProbe.snapshot(reset: true) }
            }
        }
        pdfView.autoScales = originalAutoScales
        try finishFrame()
        report.add("zoom ⌃+wheel: one tick during the burst (F4Z, with coalescing)", samplesMs: withGate, note: "\(ticks) ticks between 104% and 140%", breakdown: gateBreakdown)
        report.add("zoom ⌃+wheel: end of burst (alignment rebuild)", samplesMs: endSamples, note: "`endZoomGesture` + frame", breakdown: [:])
        report.add("zoom: one tick WITHOUT coalescing (⌘+/⌘−, every tick rebuilds)", samplesMs: withoutGate, note: "reference", breakdown: noGateBreakdown)
    }

    // MARK: - Page jump from the contents

    func pageJump() async throws {
        let entries = built.tocEntries
        var frames: [PerfBenchHost.FrameCost] = []
        var index = 0
        if !entries.isEmpty {
            let outcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
                model.goToTocEntry(entries[index % entries.count])
                index += 1
                frames.append(try finishFrame())
            }
            frames = Array(frames.suffix(config.reps))
            addSplit("jump to a heading from the contents", outcome: outcome, frames: frames, note: "\(entries.count) entries; `goToTocEntry` (heading at the top of the screen)")
        }
        frames = []
        let pages = model.pageCount
        let outcome = try await PerfBenchRunner.run(warmup: warmup, reps: config.reps) { _ in
            model.goToPage((index * 7) % pages)
            index += 1
            frames.append(try finishFrame())
        }
        frames = Array(frames.suffix(config.reps))
        addSplit("jump to a page (thumbnails/Go menu)", outcome: outcome, frames: frames, note: "`goToPage`, jumps of 7 pages")
        model.goToPage(0)
        try finishFrame()
    }

    // MARK: - Sidebar

    func sidebarToggle() async throws {
        var frames: [PerfBenchHost.FrameCost] = []
        let outcome = try await PerfBenchRunner.run(warmup: 2, reps: min(config.reps, 12)) { _ in
            model.toggleSidebar()
            frames.append(try finishFrame())
        }
        if !model.sidebarVisible { model.toggleSidebar(); try finishFrame() }
        addSplit("sidebar: show/hide (⌃⌘S)", outcome: outcome, frames: Array(frames.suffix(min(config.reps, 12))), note: "first frame of the three-column relayout (the 180 ms animation follows)")
    }

    // MARK: - Concept map

    func mapOpen() async throws {
        let reps = min(config.reps, 5)
        var firstFrame: [Double] = []
        var ready: [Double] = []
        var breakdown: [String: PerfProbe.Entry] = [:]
        for rep in 0 ..< (reps + 1) {
            let measured = rep >= 1
            if measured { PerfProbe.reset() }
            let start = CFAbsoluteTimeGetCurrent()
            model.openExpandedMap()
            try finishFrame()
            let first = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, (PerfProbe.snapshot()["map.build.await"]?.count ?? 0) == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            try finishFrame()
            let total = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if measured { firstFrame.append(first); ready.append(total); merge(&breakdown, PerfProbe.snapshot(reset: true)) }
            model.closeExpandedMap()
            try finishFrame()
            try await host.pump(seconds: 0.2)
        }
        report.add("concept map: opening (first frame)", samplesMs: firstFrame, note: "`openExpandedMap` + overlay layout", breakdown: breakdown)
        report.add("concept map: ready on screen", samplesMs: ready, note: "includes the 120 ms debounce and the build off the MainActor", breakdown: [:])
    }

    // MARK: - Opening and switching documents

    func firstPaintAndSwitch() async throws {
        let data = try Data(contentsOf: config.pdfURL)
        var initSamples: [Double] = []
        var paintSamples: [Double] = []
        var switchSamples: [Double] = []
        var breakdown: [String: PerfProbe.Entry] = [:]
        var lastHost: PerfBenchHost?
        for rep in 0 ..< 3 {
            PerfProbe.reset()
            let start = CFAbsoluteTimeGetCurrent()
            let fileDocument = PDFFileDocument(data: data, displayName: "bench-\(rep).pdf")
            guard let fresh = DocumentModel(document: fileDocument, fileURL: nil) else { continue }
            initSamples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let second = PerfBenchHost(model: fresh, size: config.windowSize, onScreen: config.onScreen)
            second.hosting.layoutSubtreeIfNeeded()
            second.hosting.layoutSubtreeIfNeeded()
            HeavyTestSuites.PerformanceBenchmarkTests.spinOnce()
            second.frame()
            paintSamples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            merge(&breakdown, PerfProbe.snapshot(reset: true))

            // Document switch: the other window becomes the active one.
            OpenDocuments.shared.register(fresh)
            let switchStart = CFAbsoluteTimeGetCurrent()
            OpenDocuments.shared.markActive(model)
            try finishFrame()
            OpenDocuments.shared.markActive(fresh)
            HeavyTestSuites.PerformanceBenchmarkTests.spinOnce()
            second.frame()
            switchSamples.append((CFAbsoluteTimeGetCurrent() - switchStart) * 1000)

            // The real pipeline starts from `PDFKitView.makeNSView`: wait for
            // it (outside the measurement) so as not to let it run past the
            // end of the test.
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, fresh.pipelineState != .ready { try await Task.sleep(for: .milliseconds(20)) }
            OpenDocuments.shared.unregister(fresh)
            lastHost?.close()
            lastHost = second
        }
        lastHost?.close()
        report.add("opening: `DocumentModel.init` (PDFDocument, annotations, native contents)", samplesMs: initSamples, note: "", breakdown: [:])
        report.add("opening: first page on screen (init + window + first layout + drawing)", samplesMs: paintSamples, note: "without the pipeline (it starts afterwards, in the background)", breakdown: breakdown)
        report.add("document switch (two windows, registry + frame of each)", samplesMs: switchSamples, note: "the real window switch is AppKit's: not measurable off-screen", breakdown: [:])
    }
}
