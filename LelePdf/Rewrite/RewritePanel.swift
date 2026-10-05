import SwiftUI

/// Content of the right-hand panel (SPEC §5.6): status banners at the top,
/// rows in document order, and the "Analyze next block" button at the bottom
/// with a 72 pt margin. The header stays in `App/RightPanel.swift`.
///
/// The rows live in `RewriteRowStack`, a LAZY stack: it builds only the rows
/// in a window around the visible part and keeps the others as heights in
/// `RewritePanelGeometry`, which also supplies the rectangles for linked
/// scrolling (SPEC §5.8). The `body` of this view no longer reads either the
/// focused block or the current page: the card accent (`FocusAccentBar`) and
/// "Continue with the next one" (`ContinueButtonRow`) observe them on their
/// own, so a hover or a page jump does not re-evaluate the stack.
struct RewritePanel: View {
    /// Not `private`: `RewritePanelBanners.swift` (same view, separate file
    /// to keep files under ~12 KB) uses it inside `var banners`.
    @Environment(DocumentModel.self) var model

    var body: some View {
        // The panel sits in a real NSScrollView (SPEC §5.8, §13, see
        // `Sync/RewriteScrollHost.swift`). The laziness does not come from
        // `LazyVStack` (without a SwiftUI `ScrollView` it is not lazy, and
        // with one its internal geometry would be unknowable: see
        // `RewritePanelGeometry`) but from `RewriteRowStack`.
        RewriteScrollHost(model: model) {
            VStack(alignment: .leading, spacing: RewritePanelGeometry.rowSpacing) {
                // `PerfProbe`: counts re-evaluations of this body.
                let _ = PerfProbe.hit("swiftui.RewritePanel.body")
                banners
                granularityStartCard
                ContinueButtonRow()
                let rows = RewriteViewModel.mergedRows(segments: model.analysisController.documentOrderSegments(), orphans: model.orphanBlocks)
                if rows.isEmpty {
                    emptyState
                } else {
                    RewriteRowStack(rows: rows, specs: Self.specs(for: rows, model: model))
                }
                analyzeNextButton
            }
            .padding(14)
            .padding(.bottom, DSMetrics.rightPanelBottomMargin)
        }
        .task { await ClaudeStatusModel.shared.refresh() }
    }

    /// Lightweight row shapes: built from the saved `BlockAnalysis` alone,
    /// microseconds per row.
    static func specs(for rows: [RewriteRow], model: DocumentModel) -> [RewriteRowSpec] {
        let analyses = model.analysisController.context?.analysis.blocks ?? [:]
        return rows.map { row in
            switch row {
            case .block(_, let blockId):
                return RewriteRowSpec(id: row.id, shape: RewriteRowShape.shape(for: row, analysis: analyses[blockId]))
            default:
                return RewriteRowSpec(id: row.id, shape: RewriteRowShape.shape(for: row, analysis: nil))
            }
        }
    }

    private var emptyState: some View {
        Text(model.pipelineState == .idle || model.structure == nil ? "Analyzing the text…" : "No blocks to show.")
            .font(.system(size: 12.5))
            .foregroundStyle(DSColor.textSecondary)
            .padding(.vertical, 20)
    }

    // MARK: - "Analyze next block" button (SPEC §5.5, ⌘↩)

    private var analyzeNextButton: some View {
        Button {
            model.analysisController.analyzeNext(fromReadingPosition: model.analysisController.readingPositionBlock(currentPageIndex: model.currentPageIndex))
        } label: {
            HStack {
                Spacer()
                Text(RewriteViewModel.analyzeNextButtonText).font(.system(size: 12.5, weight: .semibold))
                Text("⌘↩").font(.system(size: 10.5)).foregroundStyle(DSColor.textTertiary)
                Spacer()
            }
            .padding(.vertical, 10)
            .background(DSColor.cardBackground)
            .overlay(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard).stroke(DSColor.borderCard, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard))
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }
}

/// "Continue with the next one" button: a generic, stable title in first
/// position, with the section number only as a subtitle (now genuinely
/// correct, see `AnalysisController.continueBlockId`). An earlier version
/// showed a section number that looked stuck on one value, hence the
/// generic title. It is a view of its own because it is the only part of the
/// panel that depends on the current page, and it reads the page by itself,
/// with a single anchor lookup (`continueBlockId`, not also `continueLabel`,
/// which would repeat it).
private struct ContinueButtonRow: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        if let blockId = model.analysisController.continueBlockId(currentPageIndex: model.currentPageIndex) {
            Button {
                model.analysisController.analyze(blockId: blockId)
            } label: {
                HStack {
                    Image(systemName: "arrow.uturn.forward.circle.fill")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Continue with the next one").font(.system(size: 12, weight: .medium))
                        Text("Section \(model.analysisController.humanBlockLabel(for: blockId))").font(.system(size: 10)).foregroundStyle(DSColor.textSecondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(DSColor.accentBackground)
                .overlay(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard).stroke(DSColor.accentBorder, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DSColor.accent)
        }
    }
}

/// Saved analysis that no longer matches the current segmentation (SPEC §7.3).
/// The requirement is to keep old ones readable and exportable until
/// replaced. "Readable" here means a popover with the real content
/// (`AnalysisController.orphanCardData`), not the main panel: the row itself
/// stays at a FIXED HEIGHT (`RewriteRowShape`/`RewriteRowHeightEstimator`
/// are untouched, because the lazy stack of the right-hand panel estimates
/// the height of every row BEFORE building it, and variable-length content
/// here would break that estimate). "Exportable" is an entirely different,
/// non-lazy path: `RewriteExportModel`.
struct OrphanRow: View {
    let blockId: String
    let page: Int
    @Environment(DocumentModel.self) private var model
    @State private var showingContent = false

    var body: some View {
        CardContainer {
            HStack {
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
                Text("orphan")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Capsule())
                Spacer()
                Button("Show") { showingContent = true }
                    .font(.system(size: 10.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(DSColor.accent)
                    .popover(isPresented: $showingContent) { OrphanContentPopover(blockId: blockId, page: page) }
                PageChip(page: page) { model.goToPage(page) }
            }
        }
    }

    private var title: String {
        model.analysisController.orphanCardData(for: blockId, page: page)?.title ?? String(localized: "Saved analysis (previous block)")
    }
}

/// Full content of an orphan analysis ("readable"): read-only, flat text (no
/// hover link to the marks in the PDF, since the block is no longer in the
/// current segmentation).
private struct OrphanContentPopover: View {
    let blockId: String
    let page: Int
    @Environment(DocumentModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let data = model.analysisController.orphanCardData(for: blockId, page: page) {
                    Text(data.title).font(.system(size: 12.5, weight: .semibold))
                    ForEach(Array(data.rewrite.enumerated()), id: \.offset) { _, item in
                        OrphanItemText(item: item)
                    }
                } else {
                    Text("No saved content.").font(.system(size: 11.5)).foregroundStyle(DSColor.textSecondary)
                }
            }
            .padding(12)
        }
        .frame(width: 320, height: 260)
    }
}

/// One rewrite item as flat text: `.outline` lines (all new analyses) are
/// rendered one per line with a simple prefix; a legacy `kind` from before
/// the outline format is rendered from its own fields, so an old
/// `analisi.json` never crashes (same spirit as `RewriteOutlineReader`).
private struct OrphanItemText: View {
    let item: AnalysisController.ResolvedRewriteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let lines = item.lines {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    (Text(prefix(for: line.type)).foregroundStyle(DSColor.textTertiary) + plainText(line.segments))
                        .font(.system(size: 11))
                        .padding(.leading, line.type.isNested ? 12 : 0)
                }
            } else if let segments = item.segments {
                plainText(segments).font(.system(size: 11))
            } else if let itemSegments = item.itemSegments {
                ForEach(Array(itemSegments.enumerated()), id: \.offset) { _, segs in
                    (Text("• ").foregroundStyle(DSColor.textTertiary) + plainText(segs)).font(.system(size: 11))
                }
            }
        }
    }

    private func prefix(for type: RewriteLineType) -> String {
        switch type {
        case .point: "• "
        case .consequence: "→ "
        case .subpoint: "– "
        case .explanation, .note, .formula, .subheading, .definition, .example, .other: ""
        }
    }

    private func plainText(_ segments: [AnalysisController.ResolvedSegment]) -> Text {
        segments.reduce(Text("")) { partial, segment in
            switch segment {
            case .plain(let text): partial + Text(text)
            case .marked(let text, _, _, _): partial + Text(text).foregroundStyle(DSColor.textPrimary).italic()
            }
        }
    }
}
