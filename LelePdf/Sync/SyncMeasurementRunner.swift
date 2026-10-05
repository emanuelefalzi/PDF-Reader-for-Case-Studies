import Foundation
import AppKit

/// Automatic measurement run (SPEC §5.8 "How it is measured"; the fallback):
/// a Debug menu action "Measure scrolling" plus an automatic start with
/// `LELEPDF_MEASURE_AUTORUN=1`, instead of an XCUITest target. Reason: the
/// ad-hoc signed test app hangs on privacy permissions in this environment
/// and a UI test target would in any case need the Accessibility permission
/// to drive system events, and no one was at the Mac to grant it.
///
/// It scrolls both sides by setting the `NSScrollView` origin directly
/// (`DocumentSpace.scroll`, exactly as `ScrollSyncCoordinator` itself does
/// for a real scroll): the `boundsDidChangeNotification` that follows is
/// the same one a real user gesture would trigger, so the coordinator
/// reacts and records the samples in the same way. It also generates a few
/// synthetic hovers over the marks actually present in the current analysis
/// (real data, no call to Claude: zero budget).
@MainActor
enum SyncMeasurementRunner {
    static func run(model: DocumentModel) async {
        guard model.syncCoordinator.measurement != nil else { return }
        guard await waitUntilReady(model: model) else {
            log("data not ready within the time limit, measurement skipped")
            return
        }
        // Let the right panel publish the row rectangles (one SwiftUI layout
        // pass) before reading the segments.
        try? await Task.sleep(for: .milliseconds(500))
        model.syncCoordinator.rebuildAlignment()
        guard !model.syncCoordinator.segments.isEmpty else {
            log("no aligned segments, measurement skipped")
            return
        }
        debugDumpSegments(model.syncCoordinator.segments, label: model.syncCoordinator.measurement?.label ?? "unknown")

        await scrollSequence(model: model, side: .pdf)
        await scrollSequence(model: model, side: .panel)
        await hoverSequence(model: model)

        if let url = model.syncCoordinator.measurement?.flush() {
            log("wrote \(url.path)")
        }
    }

    private static func waitUntilReady(model: DocumentModel) async -> Bool {
        for _ in 0 ..< 50 { // up to ~10 s
            if model.analysisController.context != nil, !model.analysisController.documentOrderSegments().isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// Scrolls from top to bottom in small steps (SPEC §9 "60 fps"): enough
    /// samples for a sensible minimum/median/95th percentile without making
    /// the run take too long.
    ///
    /// Small, constant step in points (not a fixed number of steps):
    /// SPEC §5.8 measures the deviation during a real continuous scroll,
    /// which advances only a little on each frame. A first attempt with just
    /// 30 uniform steps over the whole document advanced by ~900+ pt per
    /// step (a whole segment or more): `AlignmentModel.segmentAt`
    /// interpolates past the end of the starting segment with a fraction
    /// `f` proportional to *its* height (SPEC "interpolate the gaps"), which
    /// the target formula then applies to the height of the corresponding
    /// segment on the other side. When the two sides have very different
    /// per-segment heights (a whole PDF page against a 44 pt placeholder), a
    /// big jump skews the measured deviation without being a real problem of
    /// the algorithm under a real, continuous scroll. Chosen step: ~24 pt (a
    /// normal/fast on-screen scrolling rhythm), with a cap on the total
    /// steps so the run does not get too long on very long documents.
    private static let scrollStepPt: CGFloat = 24
    private static let maxScrollSteps = 900

    private static func scrollSequence(model: DocumentModel, side: SyncSide) async {
        guard let scrollView = side == .pdf ? model.syncCoordinator.pdfScrollViewForMeasurement : model.syncCoordinator.panelScrollViewForMeasurement else { return }
        let maxScroll = DocumentSpace.maxScrollTopDown(scrollView)
        guard maxScroll > 0 else { return }
        let steps = min(maxScrollSteps, max(1, Int((maxScroll / scrollStepPt).rounded(.up))))
        for step in 0 ... steps {
            let top = min(maxScroll, CGFloat(step) * scrollStepPt)
            DocumentSpace.scroll(scrollView, topDownTop: top)
            try? await Task.sleep(for: .milliseconds(6))
        }
        // Go back to the top, so the side is left in a clean state for the
        // next sequence (opposite side or manual restart).
        DocumentSpace.scroll(scrollView, topDownTop: 0)
        try? await Task.sleep(for: .milliseconds(35))
    }

    private static func hoverSequence(model: DocumentModel) async {
        guard let context = model.analysisController.context else { return }
        // `blockId` is now part of the hover's identity (`markId` alone is
        // not unique in the document): carried here together with the mark,
        // not just its id.
        let sampleMarks = context.analysis.blocks.flatMap { blockId, block in
            block.marks.filter { !$0.hidden }.map { (blockId: blockId, mark: $0) }
        }.prefix(12)
        for (blockId, mark) in sampleMarks {
            model.setHover(termId: mark.termId, markId: mark.id, blockId: blockId)
            try? await Task.sleep(for: .milliseconds(60))
        }
        model.setHover(termId: nil, markId: nil)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write("scroll-measurement: \(message)\n".data(using: .utf8) ?? Data())
    }

    // TEMPORARY (diagnosing the p95 deviation beyond the threshold in the
    // first measurement run): writes a summary of the segments to
    // ~/Library/Caches/LelePdf/measure/, to be removed after the diagnosis.
    private static func debugDumpSegments(_ segments: [AlignmentSegment], label: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LelePdf/measure", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = ["n=\(segments.count)"]
        for s in segments {
            lines.append("\(s.id)\tpdf=\(Int(s.pdfStart))..\(Int(s.pdfEnd))(h=\(Int(s.pdfHeight)))\tpanel=\(Int(s.panelStart))..\(Int(s.panelEnd))(h=\(Int(s.panelHeight)))")
        }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("debug-segments-\(label).txt"), atomically: true, encoding: .utf8)
    }
}
