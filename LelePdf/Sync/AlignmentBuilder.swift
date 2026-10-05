import Foundation
@preconcurrency import PDFKit

/// Builds the ordered sequence of `AlignmentSegment`s (SPEC §5.8) from the
/// segments in document order already available from the analysis
/// (`AnalysisController.documentOrderSegments()`, passed through
/// `RewriteViewModel.rows(from:)` to reuse the same row `id` the right
/// panel already draws, so the rectangles of the geometry model
/// (`RewritePanelGeometry.rowFrames()`) line up key by key without having
/// to rebuild a second id scheme).
///
/// **Knot-based mapping**: the PDF ↔ panel map is a polyline of **knots**
/// (`Knot`: a y in the PDF and the corresponding y in the panel), no longer
/// one row = one segment with the gaps "closed" by stretching each segment
/// up to the next one (the earlier `closeGaps`). That design was the
/// measured cause of the steady-state deviation (median 57-150 pt, maxima
/// of 700-2900 pt on the Merck case): a block's segment ended where the
/// NEXT row STARTED, and that row could be a title/Exhibit anchor
/// approximated to the page (top or bottom), inside the block itself when
/// the block continues on the next page (`documentOrderSegments` puts a
/// page's titles BEFORE the blocks that continue onto it), or simply after
/// a large gap (figure, page change) smeared over the card.
///
/// Block knots: top and bottom of each GROUP of contiguous lines (a
/// paragraph: per page, split where between two lines there is a gap taller
/// than the line spacing: space between paragraphs, figure, table, page
/// change), with the card fraction equal to the fraction of TEXT covered (a
/// gap inside the block does not consume card). Blocks that OVERLAP in the
/// PDF (Exhibit pages: side-by-side tables and notes, interleaved lines; 9
/// of the 45 blocks of the Merck case) split the overlapping part in half,
/// in reading order: the polyline stays monotonic on both sides and every
/// `b-<id>` row keeps its own segment. Title and Exhibit knots: just the
/// top of the row, at the title's true anchor (`TocEntry.pageY`, when there
/// is one) or at the top/bottom of the page, accepted ONLY if they really
/// fall between the preceding and following block in both spaces;
/// otherwise the row lives inside the gap between the two cards, which the
/// polyline crosses anyway. Between two consecutive knots the interpolation
/// is linear (SPEC "start_B(i) + f × height_B(i)").
@MainActor
enum AlignmentBuilder {
    static let anchorHeight: CGFloat = 22
    /// Vertical gap (page space, PDF points) beyond which two lines of the
    /// same block belong to different groups: a little more than the line
    /// spacing (`clusterGapLines` × the block's median line height, not less
    /// than `clusterGapMin`). The lines of a paragraph stay together; the
    /// space between paragraphs, a title, a figure or a page change split.
    /// A group = a paragraph: inside it, the text is evenly distributed and
    /// linear interpolation holds. Measured: wider groups (two lines of
    /// threshold) left up to 117 pt of deviation where the spaces between
    /// paragraphs concentrate in half of the group. The panel pauses for the
    /// 9-12 pt of a paragraph gap: a few frames, while the PDF has no text
    /// there.
    static let clusterGapLines: CGFloat = 0.6
    static let clusterGapMin: CGFloat = 3
    /// Overlap (document space) tolerated between a block and the previous
    /// one before merging them into a group.
    static let overlapTolerance: CGFloat = 2

    struct Knot {
        var id: String
        var pdf: CGFloat
        var panel: CGFloat
        var isBlock: Bool
    }

    /// `panelRowFrames`: row id → rectangle in panel space (already
    /// "scrolling downward"; `RewriteFlippedHostingView` is forced flipped
    /// on purpose; see `RewriteScrollHost.swift`).
    static func build(model: DocumentModel, panelRowFrames: [String: CGRect]) -> [AlignmentSegment] {
        PerfProbe.measure("sync.alignment.build") { buildBody(model: model, panelRowFrames: panelRowFrames) }
    }

    private static func buildBody(model: DocumentModel, panelRowFrames: [String: CGRect]) -> [AlignmentSegment] {
        guard let bridge = model.readerBridge, let context = model.analysisController.context else { return [] }
        let rows = RewriteViewModel.rows(from: model.analysisController.documentOrderSegments())
        // One map built per call, every row O(1).
        let blocksById = Dictionary(uniqueKeysWithValues: context.blocks.map { ($0.id, $0) })
        var headingY: [String: Double] = [:]
        for entry in model.analysisController.allTocEntries {
            if let pageY = entry.pageY { headingY["\(entry.page)|\(entry.title)"] = pageY }
        }

        // 1. Blocks with their text extents, in row order.
        struct BlockEntry { let rowIndex: Int; let id: String; let rect: CGRect; let spans: [(top: CGFloat, bottom: CGFloat, text: CGFloat)] }
        var entries: [BlockEntry] = []
        for (rowIndex, row) in rows.enumerated() {
            guard case .block(_, let blockId) = row, let rect = panelRowFrames[row.id], let block = blocksById[blockId] else { continue }
            let spans = textSpans(block: block, bridge: bridge)
            guard let first = spans.first, let last = spans.last, last.bottom > first.top else { continue }
            entries.append(BlockEntry(rowIndex: rowIndex, id: row.id, rect: rect, spans: spans))
        }
        guard !entries.isEmpty else { return [] }

        // 2. Block knots (authoritative), monotonic by construction in the
        //    panel and made monotonic in the PDF: a block that starts above
        //    the bottom of those preceding it (Exhibit pages: side-by-side
        //    tables and notes, interleaved lines) splits the overlapping
        //    part with them in half: the preceding knots beyond the middle
        //    are moved back there, and the block starts from there. Each
        //    block thus keeps a part of the PDF of its own in reading order,
        //    instead of being squashed to zero (the earlier
        //    `enforceMonotonic`) or smeared over a whole group.
        var blockKnots: [[Knot]] = []
        var rowIndexOfBlockKnots: [Int] = []
        var lastPDF = -CGFloat.infinity
        for entry in entries {
            let total = entry.spans.reduce(CGFloat(0)) { $0 + $1.text }
            if !blockKnots.isEmpty, entry.spans[0].top < lastPDF - Self.overlapTolerance {
                let overlapEnd = min(lastPDF, entry.spans.last!.bottom)
                let middle = overlapEnd > entry.spans[0].top ? (entry.spans[0].top + overlapEnd) / 2 : lastPDF
                for b in blockKnots.indices.reversed() {
                    var changed = false
                    for k in blockKnots[b].indices where blockKnots[b][k].pdf > middle {
                        blockKnots[b][k].pdf = middle
                        changed = true
                    }
                    if !changed { break }
                }
                lastPDF = middle
            }
            var knots: [Knot] = []
            var covered: CGFloat = 0
            for (k, span) in entry.spans.enumerated() {
                let startFraction = covered / total
                covered += span.text
                let endFraction = covered / total
                let top = max(span.top, lastPDF)
                let bottom = max(span.bottom, top)
                lastPDF = bottom
                knots.append(Knot(id: k == 0 ? entry.id : "\(entry.id)#\(k)", pdf: top, panel: entry.rect.minY + startFraction * entry.rect.height, isBlock: true))
                knots.append(Knot(id: "\(entry.id)/\(k)", pdf: bottom, panel: entry.rect.minY + endFraction * entry.rect.height, isBlock: true))
            }
            blockKnots.append(knots)
            rowIndexOfBlockKnots.append(entry.rowIndex)
        }

        // 3. Title/Exhibit knots, only where they sit between their neighbors.
        var knots: [Knot] = []
        var nextBlock = 0
        for (rowIndex, row) in rows.enumerated() {
            if nextBlock < rowIndexOfBlockKnots.count, rowIndexOfBlockKnots[nextBlock] == rowIndex {
                knots.append(contentsOf: blockKnots[nextBlock])
                nextBlock += 1
                continue
            }
            guard let rect = panelRowFrames[row.id], let anchor = anchorTop(for: row, bridge: bridge, headingY: headingY) else { continue }
            let previous = knots.last
            let following = nextBlock < blockKnots.count ? blockKnots[nextBlock].first : nil
            guard anchor >= (previous?.pdf ?? -CGFloat.infinity), anchor <= (following?.pdf ?? CGFloat.infinity),
                  rect.minY >= (previous?.panel ?? -CGFloat.infinity), rect.minY <= (following?.panel ?? CGFloat.infinity) else { continue }
            knots.append(Knot(id: row.id, pdf: anchor, panel: rect.minY, isBlock: false))
        }

        // 4. Segments between consecutive knots, plus the tail to the end.
        let pdfEnd = max(bridge.topDownPageSpan(pageIndex: max(0, model.pageCount - 1))?.bottom ?? 0, knots.last!.pdf + 1)
        let panelEnd = max(panelRowFrames.values.map(\.maxY).max() ?? 0, knots.last!.panel + 1)
        var segments: [AlignmentSegment] = []
        segments.reserveCapacity(knots.count)
        for (i, knot) in knots.enumerated() {
            let nextPDF = i + 1 < knots.count ? knots[i + 1].pdf : pdfEnd
            let nextPanel = i + 1 < knots.count ? knots[i + 1].panel : panelEnd
            segments.append(AlignmentSegment(
                id: knot.id, pdfStart: knot.pdf, pdfHeight: max(nextPDF - knot.pdf, 0),
                panelStart: knot.panel, panelHeight: max(nextPanel - knot.panel, 0)
            ))
        }
        return segments
    }

    /// Top of the anchor of a title (`TocEntry.pageY` = top edge of the
    /// title in page space, y pointing up; without it, the top of the page)
    /// or of an Exhibit reference (bottom of the page), in document space.
    /// `nil` if the page is not ready.
    private static func anchorTop(for row: RewriteRow, bridge: PDFReaderBridge, headingY: [String: Double]) -> CGFloat? {
        switch row {
        case .heading(_, let title, _, let page):
            if let pageY = headingY["\(page)|\(title)"], let pdfView = bridge.pdfView, let pdfPage = pdfView.document?.page(at: page) {
                let bounds = pdfPage.bounds(for: .mediaBox)
                let rect = CGRect(x: bounds.minX, y: CGFloat(pageY) - anchorHeight, width: bounds.width, height: anchorHeight)
                return bridge.topDownSpan(pageRect: rect, page: pdfPage)?.top
            }
            return bridge.topDownPageSpan(pageIndex: page)?.top
        case .exhibit(_, _, let page):
            guard let full = bridge.topDownPageSpan(pageIndex: page) else { return nil }
            return max(full.bottom - anchorHeight, full.top)
        case .block, .orphan:
            return nil
        }
    }

    /// Groups of contiguous lines of the block, page by page and top to
    /// bottom, in document space: the block's real text, without the gaps
    /// between pages (paragraph continuation, SPEC §7.2) or those inside a
    /// page (figures, tables) taller than `clusterGap`. `text` = text height
    /// of the group (union of the lines' intervals, without line spacing or
    /// broken runs): the group's weight in the card fraction; a more spaced
    /// line is not worth more text.
    static func textSpans(block: TextBlock, bridge: PDFReaderBridge) -> [(top: CGFloat, bottom: CGFloat, text: CGFloat)] {
        guard let pdfView = bridge.pdfView, let document = pdfView.document else { return [] }
        var spans: [(top: CGFloat, bottom: CGFloat, text: CGFloat)] = []
        for pageIndex in block.lineRectsByPage.keys.sorted() {
            guard let rects = block.lineRectsByPage[pageIndex], let page = document.page(at: pageIndex) else { continue }
            for cluster in clusters(of: rects, gap: clusterGap(for: rects)) {
                guard let union = MarkGeometry.boundingRect(of: cluster), let span = bridge.topDownSpan(pageRect: union, page: page) else { continue }
                spans.append((span.top, span.bottom, max(coveredHeight(of: cluster), 1)))
            }
        }
        return spans
    }

    /// Height covered by the union of the lines' vertical intervals (page
    /// space: the scale is uniform, the ratio does not change).
    static func coveredHeight(of rects: [CGRect]) -> CGFloat {
        var covered: CGFloat = 0
        var currentMinY = CGFloat.infinity
        var currentMaxY = -CGFloat.infinity
        for rect in rects.sorted(by: { $0.maxY > $1.maxY }) {
            if rect.maxY < currentMinY {
                if currentMaxY > currentMinY { covered += currentMaxY - currentMinY }
                currentMinY = rect.minY
                currentMaxY = rect.maxY
            } else {
                currentMinY = min(currentMinY, rect.minY)
            }
        }
        if currentMaxY > currentMinY { covered += currentMaxY - currentMinY }
        return covered
    }

    static func clusterGap(for rects: [CGRect]) -> CGFloat {
        let heights = rects.map(\.height).sorted()
        guard !heights.isEmpty else { return clusterGapMin }
        return max(clusterGapMin, heights[heights.count / 2] * clusterGapLines)
    }

    /// Lines (page space, y pointing up) split from top to bottom where the
    /// gap between two consecutive lines exceeds `gap`.
    static func clusters(of rects: [CGRect], gap: CGFloat) -> [[CGRect]] {
        let sorted = rects.sorted { $0.maxY > $1.maxY }
        var result: [[CGRect]] = []
        var current: [CGRect] = []
        var currentMinY = CGFloat.infinity
        for rect in sorted {
            if !current.isEmpty, currentMinY - rect.maxY > gap {
                result.append(current)
                current = []
                currentMinY = .infinity
            }
            current.append(rect)
            currentMinY = min(currentMinY, rect.minY)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
