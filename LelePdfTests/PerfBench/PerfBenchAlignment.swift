import Foundation
import AppKit
@preconcurrency import PDFKit
@testable import LelePdf

/// Alignment probe (F6-ALL): measures, in WINDOW coordinates, how far the
/// card of the paragraph at the PDF's reading line is from that same line.
/// Ground truth independent of the coordinator: on the PDF side the block's
/// line rectangles converted by PDFKit (`convert(_:from:)` +
/// `convert(_:to: nil)`), on the panel side the REAL rectangle of the card as
/// SwiftUI placed it (`RewritePanelGeometry.realizedFrames`), not the
/// model's rectangles.
@MainActor
struct PerfBenchAlignmentProbe {
    struct Sample {
        var kind: String
        /// Window offset: card point − PDF reading line (positive = the card
        /// is lower). "Downward" space.
        var windowErrorPt: Double
        /// Same offset but against the PANEL's reading line (30% of its
        /// visible part): the error "as SPEC §5.8 intends it".
        var specErrorPt: Double
        /// True top of the card − top according to the model (rectangles
        /// published to the coordinator): ≠ 0 = stale rectangles.
        var staleFramePt: Double
        var rowId: String
        var fraction: Double
        var boundary: Bool
        var flippedRows: Int
        var measuredBefore: Bool
        var realized: Bool
        /// Blocks that contain the reading line (>1 = overlapping blocks in
        /// the PDF, "the paragraph at the line" is ambiguous).
        var overlapping: Int
        /// Diagnostics line (lines, block, segments, card) at the time of the sample.
        var diagnostics: String = ""
    }

    let host: PerfBenchHost
    let model: DocumentModel
    let blocks: [TextBlock]
    /// Lines of each block in the PDF's document space (scrolling downward),
    /// sorted from the top: computed once (zoom does not change during the
    /// scenario).
    private let lineSpansByBlock: [String: [(top: CGFloat, bottom: CGFloat)]]

    init(host: PerfBenchHost, blocks: [TextBlock]) {
        self.host = host
        self.model = host.model
        self.blocks = blocks
        var spans: [String: [(top: CGFloat, bottom: CGFloat)]] = [:]
        if let bridge = host.model.readerBridge, let document = bridge.pdfView?.document {
            for block in blocks {
                var lines: [(top: CGFloat, bottom: CGFloat)] = []
                for (pageIndex, rects) in block.lineRectsByPage {
                    guard let page = document.page(at: pageIndex) else { continue }
                    for rect in rects {
                        if let span = bridge.topDownSpan(pageRect: rect, page: page) { lines.append(span) }
                    }
                }
                spans[block.id] = Self.mergedIntervals(lines)
            }
        }
        lineSpansByBlock = spans
    }

    /// Union of the vertical intervals (lines that overlap or touch become
    /// one), sorted from the top: the TEXT height of the block, without line
    /// spacing, gaps between pages or around figures, and without counting
    /// twice rectangles split into several runs.
    static func mergedIntervals(_ intervals: [(top: CGFloat, bottom: CGFloat)]) -> [(top: CGFloat, bottom: CGFloat)] {
        var result: [(top: CGFloat, bottom: CGFloat)] = []
        for interval in intervals.sorted(by: { $0.top < $1.top }) {
            if let last = result.last, interval.top <= last.bottom {
                result[result.count - 1].bottom = max(last.bottom, interval.bottom)
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// The PDF's reading line in document space (scrolling downward), going
    /// through the window: independent of `DocumentSpace`.
    private func pdfReadingLineInDocument() -> CGFloat? {
        guard let pdfScroll = host.pdfScrollView, let documentView = pdfScroll.documentView else { return nil }
        let windowPoint = CGPoint(x: 0, y: windowHeight - readingLine(pdfScroll))
        let inDocument = documentView.convert(windowPoint, from: nil)
        return documentView.isFlipped ? inDocument.y : documentView.bounds.height - inDocument.y
    }

    private var windowHeight: CGFloat { host.window.frame.height }

    /// Rectangle of `rect` (in `view` space) in "downward" window coordinates
    /// (0 at the top of the window).
    private func windowTopDown(_ rect: CGRect, in view: NSView) -> (top: CGFloat, bottom: CGFloat) {
        let r = view.convert(rect, to: nil)
        return (windowHeight - r.maxY, windowHeight - r.minY)
    }

    /// Reading line of a scroll view, in window coordinates: 30% of the
    /// VISIBLE height in the window (PDFKit scales the clip view's `bounds`
    /// for zoom: `bounds.height` is in page points, not window points).
    func readingLine(_ scrollView: NSScrollView) -> CGFloat {
        let clip = scrollView.contentView
        let span = windowTopDown(clip.bounds, in: clip)
        return span.top + (span.bottom - span.top) * ScrollSyncCoordinator.readingLineFraction
    }

    /// Union of the block's lines on each page, in window coordinates, in
    /// page order: the real text, without the gaps between pages.
    func blockPageSpans(_ block: TextBlock) -> [(top: CGFloat, bottom: CGFloat)] {
        guard let pdfView = model.readerBridge?.pdfView, let document = pdfView.document else { return [] }
        var spans: [(top: CGFloat, bottom: CGFloat)] = []
        for pageIndex in block.lineRectsByPage.keys.sorted() {
            guard let rects = block.lineRectsByPage[pageIndex], let page = document.page(at: pageIndex), let union = MarkGeometry.boundingRect(of: rects) else { continue }
            let inView = pdfView.convert(union, from: page)
            spans.append(windowTopDown(inView, in: pdfView))
        }
        return spans
    }

    /// Vertical extent in the window of a block (all its pages).
    func blockWindowSpan(_ block: TextBlock) -> (top: CGFloat, bottom: CGFloat)? {
        let spans = blockPageSpans(block)
        guard let first = spans.first, let last = spans.last else { return nil }
        return (first.top, last.bottom)
    }

    /// Tolerance around a line of text (line spacing): the reading line "is
    /// on the paragraph" if it falls on a line or in the line spacing.
    static let lineSlack: CGFloat = 4

    /// Block that contains the PDF's reading line, and the fraction travelled
    /// THROUGH THE TEXT: text height (union of the lines' intervals) above
    /// the line / total text height. Definition independent of the
    /// coordinator and without thresholds: no gaps between pages or around
    /// figures, no line spacing; a line inside a gap of the block is not "a
    /// paragraph at the reading line" and is discarded like any other gap.
    /// `overlapping` = how many blocks have a line under the reading line
    /// (Exhibit pages with interleaved blocks: ambiguous).
    func blockAtReadingLine() -> (block: TextBlock, fraction: Double, overlapping: Int)? {
        guard let line = pdfReadingLineInDocument() else { return nil }
        var found: (block: TextBlock, fraction: Double)?
        var count = 0
        for block in blocks {
            guard let lines = lineSpansByBlock[block.id], let first = lines.first, let last = lines.last else { continue }
            // Block-level ambiguity: the line falls within the extent
            // (first-last line) of several blocks, even if only a single line
            // of one of them touches it; the lines are interleaved.
            guard first.top - Self.lineSlack <= line, line <= last.bottom + Self.lineSlack else { continue }
            count += 1
            guard lines.contains(where: { $0.top - Self.lineSlack <= line && line <= $0.bottom + Self.lineSlack }) else { continue }
            guard found == nil else { continue }
            let total = lines.reduce(CGFloat(0)) { $0 + ($1.bottom - $1.top) }
            let above = lines.reduce(CGFloat(0)) { $0 + max(0, min($1.bottom, line) - $1.top) }
            found = (block, total > 0 ? Double(above / total) : 0)
        }
        guard let found else { return nil }
        return (found.block, found.fraction, max(count, 1))
    }

    /// Diagnostics: the block's (merged) line intervals in document space,
    /// with the gaps between consecutive intervals.
    func lineIntervalsDescription(blockId: String) -> String {
        guard let lines = lineSpansByBlock[blockId] else { return "" }
        var out = "\(lines.count) intervals:"
        for (i, line) in lines.enumerated() {
            let gap = i > 0 ? line.top - lines[i - 1].bottom : 0
            out += " \(i > 0 ? "+\(String(format: "%.0f", gap)) " : "")[\(String(format: "%.0f", line.top)),\(String(format: "%.0f", line.bottom))]"
        }
        return out
    }

    /// Top/bottom in the window of a panel row: from the view's real
    /// rectangle if built, otherwise from the model.
    func rowWindowSpan(rowId: String, useModel: Bool) -> (top: CGFloat, bottom: CGFloat)? {
        guard let container = host.panelScrollView?.documentView else { return nil }
        let geometry = model.rewritePanelGeometry
        let frame: CGRect
        if !useModel, let real = geometry.realizedFrames[rowId] {
            frame = real
        } else if let modelFrame = geometry.rowFrames()[rowId] {
            frame = modelFrame
        } else {
            return nil
        }
        return windowTopDown(frame, in: container)
    }

    var measuredRowIds: Set<String> {
        let geometry = model.rewritePanelGeometry
        return Set(geometry.rows.map(\.id).filter { geometry.isMeasured($0) })
    }

    /// A sample: `nil` if the PDF's reading line does not fall inside any
    /// block (gap between paragraphs, heading, figure).
    func sample(kind: String, previousRowId: String?, measuredBefore: Set<String>) -> Sample? {
        guard let pdfScroll = host.pdfScrollView, let panelScroll = host.panelScrollView else { return nil }
        guard let (block, fraction, overlapping) = blockAtReadingLine() else { return nil }
        let rowId = "b-\(block.id)"
        let geometry = model.rewritePanelGeometry
        let realized = geometry.realizedFrames[rowId] != nil
        guard let real = rowWindowSpan(rowId: rowId, useModel: false), let modelSpan = rowWindowSpan(rowId: rowId, useModel: true) else { return nil }
        let point = real.top + CGFloat(fraction) * (real.bottom - real.top)
        let measuredAfter = measuredRowIds
        var sample = Sample(
            kind: kind,
            windowErrorPt: Double(point - readingLine(pdfScroll)),
            specErrorPt: Double(point - readingLine(panelScroll)),
            staleFramePt: Double(real.top - modelSpan.top),
            rowId: rowId, fraction: fraction,
            boundary: previousRowId != nil && previousRowId != rowId,
            flippedRows: measuredAfter.subtracting(measuredBefore).count,
            measuredBefore: measuredBefore.contains(rowId),
            realized: realized,
            overlapping: overlapping
        )
        sample.diagnostics = diagnostics(for: sample)
        return sample
    }

    /// Diagnostics line for a sample: reading lines, block in the PDF,
    /// coordinator segment, real card, all in window coordinates.
    func diagnostics(for sample: Sample) -> String {
        guard let pdfScroll = host.pdfScrollView, let panelScroll = host.panelScrollView else { return "" }
        let blockId = String(sample.rowId.dropFirst(2))
        var out = "rl pdf=\(f(readingLine(pdfScroll))) panel=\(f(readingLine(panelScroll)))"
        if let block = blocks.first(where: { $0.id == blockId }), let span = blockWindowSpan(block) {
            out += " · block[\(f(span.top)),\(f(span.bottom))]"
        }
        if let block = blocks.first(where: { $0.id == blockId }) {
            out += " · pages " + blockPageSpans(block).map { "[\(f($0.top)),\(f($0.bottom))]" }.joined(separator: "")
        }
        if let real = rowWindowSpan(rowId: sample.rowId, useModel: false) { out += " · real card[\(f(real.top)),\(f(real.bottom))]" }
        if let (pdfTop, _) = DocumentSpace.visibleTopDown(pdfScroll), let (panelTop, _) = DocumentSpace.visibleTopDown(panelScroll) {
            let pdfClip = windowTopDown(pdfScroll.contentView.bounds, in: pdfScroll.contentView)
            let pdfScale = (pdfClip.bottom - pdfClip.top) / pdfScroll.contentView.bounds.height
            let panelClipTop = windowTopDown(panelScroll.contentView.bounds, in: panelScroll.contentView).top
            for segment in model.syncCoordinator.segments where segment.id.hasPrefix(sample.rowId) {
                out += " · seg \(segment.id.dropFirst(sample.rowId.count)) pdf[\(f((segment.pdfStart - pdfTop) * pdfScale + pdfClip.top)),\(f((segment.pdfEnd - pdfTop) * pdfScale + pdfClip.top))] pan[\(f(segment.panelStart - panelTop + panelClipTop)),\(f(segment.panelEnd - panelTop + panelClipTop))]"
            }
        }
        return out + " · f=\(f(CGFloat(sample.fraction), 2)) overlapping=\(sample.overlapping) err=\(f(CGFloat(sample.windowErrorPt)))"
    }

    func clipRects() -> String {
        guard let pdfScroll = host.pdfScrollView, let panelScroll = host.panelScrollView else { return "" }
        let p = windowTopDown(pdfScroll.contentView.bounds, in: pdfScroll.contentView)
        let r = windowTopDown(panelScroll.contentView.bounds, in: panelScroll.contentView)
        return "clip PDF [\(f(p.top)),\(f(p.bottom))] (bounds h \(f(pdfScroll.contentView.bounds.height)), insets \(pdfScroll.contentInsets.top)/\(pdfScroll.contentInsets.bottom)) · clip panel [\(f(r.top)),\(f(r.bottom))] (bounds h \(f(panelScroll.contentView.bounds.height)), frame h \(f(panelScroll.frame.height)))"
    }

    private func f(_ v: CGFloat, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", v) }

    /// Diagnostics (temporary): extent per page of each block in document
    /// space, in line order, with the blocks that overlap the previous one
    /// and the list of lines with the gaps.
    func blocksTable() -> String {
        guard let bridge = model.readerBridge, let pdfView = bridge.pdfView, let document = pdfView.document else { return "" }
        let rows = RewriteViewModel.rows(from: model.analysisController.documentOrderSegments())
        var out = "| # | block | pages | extent per page (doc) | lines per page | notes |\n|---|---|---|---|---|---|\n"
        var lastBottom = -CGFloat.infinity
        var index = 0
        for row in rows {
            guard case .block(_, let blockId) = row, let block = blocks.first(where: { $0.id == blockId }) else { continue }
            var spans: [String] = []
            var counts: [String] = []
            var note = ""
            var first = true
            for pageIndex in block.lineRectsByPage.keys.sorted() {
                guard let rects = block.lineRectsByPage[pageIndex], let page = document.page(at: pageIndex), let union = MarkGeometry.boundingRect(of: rects), let span = bridge.topDownSpan(pageRect: union, page: page) else { continue }
                spans.append("p\(pageIndex + 1)[\(f(span.top)),\(f(span.bottom))]")
                let sorted = rects.map(\.minY).sorted(by: >)
                var gaps = 0
                for i in 1 ..< max(1, sorted.count) where sorted[i - 1] - sorted[i] > 60 { gaps += 1 }
                counts.append("\(rects.count)\(gaps > 0 ? " (\(gaps) gaps >60)" : "")")
                if first, span.top < lastBottom { note += "overlaps the previous one by \(f(lastBottom - span.top)) " }
                first = false
                lastBottom = max(lastBottom, span.bottom)
            }
            out += "| \(index) | \(blockId.prefix(6)) | \(block.pageStart + 1)-\(block.pageEnd + 1) | \(spans.joined(separator: " ")) | \(counts.joined(separator: " ")) | \(note) |\n"
            if index < 3 { out += "| | | | \(lineIntervalsDescription(blockId: blockId)) | | |\n" }
            index += 1
        }
        return out
    }

    /// Difference between the reading lines of the two sides, in window
    /// coordinates (panel − PDF): a constant "definition" error.
    func readingLineOffset() -> CGFloat? {
        guard let pdf = host.pdfScrollView, let panel = host.panelScrollView else { return nil }
        return readingLine(panel) - readingLine(pdf)
    }

    /// Cross-check: top of the card's `MarkedNSTextView`s (AppKit) − top of
    /// the real rectangle (SwiftUI). Must be a constant (card padding +
    /// header).
    func textViewsOffset(rowId: String, blockId: String) -> CGFloat? {
        guard let container = host.panelScrollView?.documentView, let real = rowWindowSpan(rowId: rowId, useModel: false) else { return nil }
        var views: [MarkedNSTextView] = []
        collect(container, into: &views)
        let tops = views.filter { $0.blockId == blockId && $0.bounds.height > 0 }.map { windowTopDown($0.bounds, in: $0).top }
        guard let top = tops.min() else { return nil }
        return top - real.top
    }

    private func collect(_ view: NSView, into result: inout [MarkedNSTextView]) {
        if let text = view as? MarkedNSTextView { result.append(text) }
        for subview in view.subviews { collect(subview, into: &result) }
    }
}

/// Statistics of a group of samples: median |error|, p90, max, plus the
/// signed median (systematic bias).
struct PerfBenchAlignmentStats {
    let values: [Double]

    var count: Int { values.count }
    var absStats: PerfBenchStats { PerfBenchStats(samplesMs: values.map(abs)) }
    var signedMedian: Double { PerfBenchStats(samplesMs: values).median }

    static func row(_ name: String, _ values: [Double], note: String = "") -> String {
        guard !values.isEmpty else { return "| \(name) | 0 | — | — | — | — | \(note) |\n" }
        let stats = PerfBenchAlignmentStats(values: values)
        let a = stats.absStats
        func pt(_ v: Double) -> String { String(format: "%.1f", v) }
        return "| \(name) | \(stats.count) | \(pt(a.median)) | \(pt(a.p90)) | \(pt(a.max)) | \(pt(stats.signedMedian)) | \(note) |\n"
    }

    static let header = "| Group | n | median \\|err\\| | p90 | max | signed median | notes |\n|---|---|---|---|---|---|---|\n"
}
