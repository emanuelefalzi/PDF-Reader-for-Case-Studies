import SwiftUI

/// LAZY stack of the right-hand panel rows.
///
/// It is not a `LazyVStack`: SwiftUI would only know the position of the rows
/// it has built and would estimate the others itself (in a non-observable
/// way), whereas linked scrolling (SPEC §5.8) needs the start and height of
/// EVERY row, exact where the user is looking and consistent with what the
/// view shows. Here the geometry belongs to `RewritePanelGeometry`: a
/// `RewriteRowsLayout` (below) holds ONLY the rows of the built window, with
/// a filler above equal to the sum of the preceding rows and one below equal
/// to the sum of the following ones. Built rows take their natural height
/// (same width proposal as before, so a single card lays out identically,
/// with no overlaps) and report it to the model through
/// `onGeometryChange`, which replaces the estimate and recomputes the
/// fillers and the rectangles for the coordinator.
///
/// The `body` observes ONE property (`revision`) and rebuilds the `ForEach`
/// over the few rows in the window: cards outside the window do not exist,
/// so every invalidation of the panel costs the layout of 4-8 rows instead of
/// all of them.
struct RewriteRowStack: View {
    let rows: [RewriteRow]
    let specs: [RewriteRowSpec]
    @Environment(DocumentModel.self) private var model

    var body: some View {
        let geometry = model.rewritePanelGeometry
        let _ = geometry.revision // the only observation: window/fillers changed
        let _ = PerfProbe.hit("swiftui.RewriteRowStack.body")
        let plan = geometry.plan(for: specs)
        RewriteRowsLayout(
            topPadding: plan.topPadding, bottomPadding: plan.bottomPadding,
            measuredHeights: plan.measuredHeights, modelHeights: plan.modelHeights, spacing: RewritePanelGeometry.rowSpacing,
            lastRowIncluded: plan.range.upperBound == rows.count
        ) {
            ForEach(rows[plan.range], id: \.id) { row in
                rowView(row)
                    // The row's TRUE rectangle in content space (not just its
                    // size): the position is needed by the alignment
                    // benchmark (`PerfBench`) to compare where the card
                    // really is with where the model thinks it is, at the
                    // same cost as before.
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(RewriteSyncCoordinateSpace.name))
                    } action: { frame in
                        geometry.report(id: row.id, frame: frame)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Top and width of the stack in scrollable content space (SPEC §5.8
        // "a vertical interval ... in the right-hand panel content"): the row
        // rectangles start from here.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(RewriteSyncCoordinateSpace.name))
        } action: { frame in
            geometry.updateFrame(originY: frame.minY, width: frame.width)
        }
        .onChange(of: specs, initial: true) { _, newSpecs in
            geometry.commit(newSpecs)
        }
    }

    @ViewBuilder
    private func rowView(_ row: RewriteRow) -> some View {
        switch row {
        case .heading(_, let title, let level, _):
            HeadingRow(title: title, level: level)
        case .block(_, let blockId):
            // `cardData`/`isRegenerating` are computed HERE (once, for the
            // row that is about to be evaluated anyway) and passed as
            // concrete values to `BlockCardView.equatable()`. This lets
            // SwiftUI skip redrawing cards whose block has not changed,
            // instead of redrawing them all on every mark touched anywhere
            // in the document (see the comment on `BlockCardView`).
            // `isCurrent` no longer comes from here (it would re-evaluate
            // the stack on every hover/jump): the card observes the accent
            // itself (`FocusAccentBar`); `false` = "no forced accent".
            // The "3.2" label also comes from here (this body re-reads
            // `context` for `cardData` anyway), so the card's `body` no
            // longer depends on the whole context.
            if let data = model.analysisController.cardData(for: blockId) {
                BlockCardView(
                    blockId: blockId, cardData: data,
                    isRegenerating: model.analysisController.isRegenerating(blockId: blockId),
                    isCurrent: false,
                    humanLabel: model.analysisController.humanBlockLabel(for: blockId)
                )
                .equatable()
            } else {
                BlockPlaceholderView(blockId: blockId)
            }
        case .exhibit(_, let label, let page):
            ExhibitRow(label: label, page: page)
        case .orphan(_, let blockId, let page):
            OrphanRow(blockId: blockId, page: page)
        }
    }
}

/// Accent bar of the focused card: a minimal view that observes
/// `DocumentModel.currentFocusedBlockId` and the subject color by itself. It
/// is always present, with opacity 0/1, and changes neither the structure nor
/// the size of the card. The accent used to go through `RewritePanel.body`
/// (`isCurrent`), so every hover between paragraphs and every page jump
/// re-evaluated and re-laid-out the whole stack (52-118 ms); now only these
/// bars are re-evaluated, one per built card. `forced` = accent on
/// regardless (`BlockCardView.isCurrent`, used by tests and previews).
struct FocusAccentBar: View {
    let blockId: String
    var forced = false
    @Environment(DocumentModel.self) private var model

    var body: some View {
        let _ = PerfProbe.hit("swiftui.FocusAccentBar.body")
        let isOn = forced || model.currentFocusedBlockId == blockId
        RoundedRectangle(cornerRadius: 1.5)
            .fill(DSColor.markColor(hue: model.colorTheme, tone: .t3))
            .frame(width: 3)
            .padding(.vertical, 3)
            .opacity(isOn ? 1 : 0)
    }
}

/// Vertical arrangement of the built rows: like a `VStack`, but with a filler
/// above and below (the unbuilt rows) and, which a `VStack` cannot do,
/// WITHOUT querying rows that are already measured. A `VStack` asks each child
/// for several sizes per pass (minimum, ideal, maximum, then the final one)
/// and every request descends to every `MarkedTextView` (~50 `sizeThatFits`
/// calls per text view per pass: 5,000-15,000 calls per invalidation even
/// with the measurement cache). Here rows with a measured height are only
/// PLACED with the usual proposal (stack width, free height), so SwiftUI
/// reuses their layout, and only new rows are actually measured
/// (`dimensions(in:)`).
struct RewriteRowsLayout: Layout {
    var topPadding: CGFloat
    var bottomPadding: CGFloat
    var measuredHeights: [CGFloat?]
    var modelHeights: [CGFloat]
    var spacing: CGFloat
    /// True if the last built row is also the last of the sequence (no
    /// spacing after it).
    var lastRowIncluded: Bool

    struct Cache {
        var width: CGFloat = -1
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func heights(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [CGFloat] {
        if cache.width == width, cache.heights.count == subviews.count { return cache.heights }
        let proposal = ProposedViewSize(width: width, height: nil)
        let resolved = subviews.indices.map { i -> CGFloat in
            if i < measuredHeights.count, let measured = measuredHeights[i] { return measured }
            MainActor.assumeIsolated { PerfProbe.hit("swiftui.RewriteRowsLayout.probe") }
            return subviews[i].dimensions(in: proposal).height
        }
        cache.width = width
        cache.heights = resolved
        return resolved
    }

    private func contentHeight(_ heights: [CGFloat]) -> CGFloat {
        guard !heights.isEmpty else { return topPadding + bottomPadding }
        let gaps = CGFloat(heights.count - (lastRowIncluded ? 1 : 0))
        return topPadding + heights.reduce(0, +) + spacing * gaps + bottomPadding
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        // Minimum/ideal/maximum proposals (0, nil, infinity): answer with the
        // model heights alone, without querying any row. The real width
        // always comes from the container (`RewriteScrollHost`).
        guard let width = proposal.width, width.isFinite, width >= 1 else {
            let heights = subviews.indices.map { $0 < modelHeights.count ? modelHeights[$0] : 0 }
            return CGSize(width: proposal.width ?? 0, height: contentHeight(heights))
        }
        return CGSize(width: width, height: contentHeight(heights(width: width, subviews: subviews, cache: &cache)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let width = bounds.width
        let heights = heights(width: width, subviews: subviews, cache: &cache)
        var y = bounds.minY + topPadding
        let proposal = ProposedViewSize(width: width, height: nil)
        for (i, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: proposal)
            y += heights[i] + spacing
        }
    }
}
