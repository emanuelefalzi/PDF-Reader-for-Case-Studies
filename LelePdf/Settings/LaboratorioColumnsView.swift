import SwiftUI

/// Right side of the Lab (SPEC §5.14): block picker plus the two
/// "Current Version"/"New Trial" columns, drawn like the real cards of
/// the right panel (`RewriteItemView`).
struct LaboratorioColumnsView: View {
    @Bindable var viewModel: LaboratorioViewModel
    let document: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            blockPicker
            Divider()
            HStack(alignment: .top, spacing: 0) {
                column(
                    title: "Current Version", card: viewModel.currentVersion, wordCount: viewModel.currentVersionWordCount,
                    emptyText: "Block not analyzed yet."
                )
                Divider()
                column(
                    title: "New Trial", card: viewModel.trialCard, wordCount: viewModel.trialWordCount,
                    emptyText: viewModel.trialError ?? "Press \u{201c}Try\u{201d} to see the effect of the edited instructions."
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            trialFooter
        }
        .padding(14)
    }

    private var blockPicker: some View {
        HStack(spacing: 10) {
            Text("Block").font(.system(size: 11.5, weight: .medium))
            Picker("Block", selection: $viewModel.selectedBlockId) {
                ForEach(viewModel.blocks) { block in
                    Text(viewModel.label(for: block)).tag(block.id as String?)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            if let count = viewModel.blockWordCount {
                Text("\(count) words in the block")
                    .font(.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }
            Spacer()
        }
    }

    private func column(title: String, card: AnalysisController.BlockCardData?, wordCount: Int?, emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let wordCount {
                    Text("\(wordCount) words").font(.caption).foregroundStyle(DSColor.textSecondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let card {
                        ForEach(Array(card.rewrite.enumerated()), id: \.offset) { _, item in
                            RewriteItemView(item: item, model: document, blockId: viewModel.selectedBlockId ?? "")
                        }
                    } else {
                        Text(emptyText)
                            .font(.caption)
                            .foregroundStyle(DSColor.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trialFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Every Trial uses a call from your subscription, like a normal analysis.",
                systemImage: "exclamationmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.runTrial() }
                } label: {
                    if viewModel.isRunningTrial {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Try")
                    }
                }
                .disabled(!viewModel.canRunTrial)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
