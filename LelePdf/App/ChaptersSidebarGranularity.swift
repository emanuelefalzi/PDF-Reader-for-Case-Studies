import SwiftUI

/// Summary granularity ("a clear control ... in the Contents tab ('Summarise
/// by: ...')"): a row below the Chapters tab header, always visible, with
/// the same value/same action as the right panel
/// (`RewritePanelGranularityControl.swift`) and the "Contents" menu
/// (`ContentsCommands.swift`): a single action (`DocumentModel
/// .requestSummaryGranularityChange`) invoked from three different
/// places. Kept in a file separate from `ChaptersSidebar.swift` to keep
/// files short.
extension ChaptersSidebar {
    var granularityRow: some View {
        HStack(spacing: 6) {
            Text(model.effectiveSummaryGranularity.summariseByLabel)
                .font(.system(size: 10.5))
                .foregroundStyle(DSColor.textSecondary)
                .lineLimit(1)
            Spacer()
            Menu {
                ForEach(SummaryGranularity.allCases) { granularity in
                    Button {
                        model.requestSummaryGranularityChange(to: granularity)
                    } label: {
                        if granularity == model.effectiveSummaryGranularity {
                            Label(granularity.label, systemImage: "checkmark")
                        } else {
                            Text(granularity.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose how finely blocks are summarised: per paragraph, per Heading 3, per Heading 2, or per chapter.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DSColor.borderSoft).frame(height: 0.5)
        }
    }
}
