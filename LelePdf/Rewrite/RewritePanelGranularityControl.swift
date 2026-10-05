import SwiftUI

/// Summary granularity control: a clear control in the empty/initial state of
/// the right-hand panel. The card is shown ONLY before the user has analyzed
/// the first block, matching the intended flow: fix the contents, choose the
/// granularity ONCE, then analysis starts. It disappears on its own as soon
/// as a first analysis arrives; from then on the control stays available in
/// the "Contents" menu and in the Contents card
/// (`ChaptersSidebarGranularity.swift`), triggering the same action
/// (`DocumentModel.requestSummaryGranularityChange`). Separate file from
/// `RewritePanel.swift` to keep files under ~12 KB.
extension RewritePanel {
    @ViewBuilder
    var granularityStartCard: some View {
        if showsGranularityStartCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(DSColor.accent)
                    Text("Summarise by").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DSColor.textPrimary)
                }
                Text("Choose how finely blocks are summarised before you start: one card per paragraph, per Heading 3, per Heading 2, or per whole chapter. You can change it later too.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DSColor.textSecondary)
                Picker("Summarise by", selection: Binding(
                    get: { model.effectiveSummaryGranularity },
                    set: { model.requestSummaryGranularityChange(to: $0) }
                )) {
                    ForEach(SummaryGranularity.allCases) { granularity in
                        Text(granularity.shortLabel).tag(granularity)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .padding(10)
            .background(DSColor.accentBackground)
            .overlay(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard).stroke(DSColor.accentBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard))
        }
    }

    /// True only when there is already something to segment but NOTHING has
    /// been analyzed yet (SPEC §5.5 "On reopening": `analyzedBlockIds` stays
    /// the single source of truth for the "before" of this choice, not
    /// `hasChosenSummaryGranularity` alone). A document with the granularity
    /// already chosen but still at zero analyses (for example just reopened
    /// after changing it) still shows this card, consistent with "choose once
    /// at the start".
    private var showsGranularityStartCard: Bool {
        guard let blocks = model.analysisController.context?.blocks, !blocks.isEmpty else { return false }
        return model.documentRecord?.progress.analyzedBlockIds.isEmpty ?? true
    }
}
