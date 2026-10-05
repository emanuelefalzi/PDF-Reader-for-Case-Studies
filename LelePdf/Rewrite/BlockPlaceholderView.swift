import SwiftUI

/// Placeholder for a block that is not analyzed yet, or is queued, in
/// progress, waiting on another window, or failed (SPEC §5.5, §5.6): a
/// single view that dispatches on `BlockQueueState`, minimum height 44 pt
/// (SPEC §5.6).
struct BlockPlaceholderView: View {
    let blockId: String
    @Environment(DocumentModel.self) private var model

    var body: some View {
        let state = model.analysisController.blockState(blockId)
        let page = model.analysisController.placeholderData(for: blockId)?.page

        Group {
            switch state {
            case .idle:
                idleRow(page: page)
            case .queued(let position):
                statusRow(text: RewriteViewModel.queuedLabel(position: position), showsSpinner: false, cancellable: true)
            case .waitingOtherWindow:
                statusRow(text: "Waiting: another window is analyzing", showsSpinner: true, cancellable: true)
            case .running(let startedAt, let estimatedSeconds):
                runningRow(startedAt: startedAt, estimatedSeconds: estimatedSeconds)
            case .failed(let error):
                failedRow(error: error)
            case .analyzed:
                EmptyView() // BlockCardView handles this case.
            }
        }
        .frame(minHeight: RewriteViewModel.placeholderMinHeight)
    }

    private func idleRow(page: Int?) -> some View {
        HStack {
            Text(RewriteViewModel.placeholderLabel(page: page ?? 0))
                .font(.system(size: 12))
                .foregroundStyle(DSColor.textSecondary)
            Spacer()
            Button("Analyze") { model.analysisController.analyze(blockId: blockId) }
                .font(.system(size: 11.5, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(DSColor.accent)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: RewriteViewModel.placeholderMinHeight)
        .background(DSColor.cardBackground.opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard).stroke(DSColor.borderCard, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])))
        .clipShape(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard))
    }

    private func statusRow(text: String, showsSpinner: Bool, cancellable: Bool) -> some View {
        CardContainer {
            HStack(spacing: 8) {
                if showsSpinner { ProgressView().controlSize(.small) }
                Text(text).font(.system(size: 12)).foregroundStyle(DSColor.textSecondary)
                Spacer()
                if cancellable {
                    Button { model.analysisController.cancel(blockId: blockId) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(DSColor.textTertiary)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func runningRow(startedAt: Date, estimatedSeconds: Double?) -> some View {
        CardContainer {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RewriteViewModel.runningLabel(humanBlockLabel: model.analysisController.humanBlockLabel(for: blockId)))
                        .font(.system(size: 12, weight: .medium))
                    if let estimatedSeconds {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            // `PerfProbe`: every tick of this counter
                            // re-evaluates the row; the benchmark measures
                            // what that costs the rest of the panel.
                            let _ = PerfProbe.hit("swiftui.BlockPlaceholderView.tick")
                            let elapsed = context.date.timeIntervalSince(startedAt)
                            Text(RewriteViewModel.etaLabel(remainingSeconds: estimatedSeconds - elapsed))
                                .font(.system(size: 10.5))
                                .foregroundStyle(DSColor.textSecondary)
                                // Performance note: each tick of this counter
                                // redoes the layout of the WHOLE panel stack
                                // (measured: 10,591 `sizeThatFits` calls, a
                                // 95-115 ms hitch every second for the whole
                                // analysis). A fixed frame plus fixed-width
                                // digits was tried and measured ineffective
                                // (same number of calls): the pass restarts
                                // from the host
                                // (`sizingOptions = [.intrinsicContentSize]`),
                                // not from the size of this `Text`. It is
                                // fixed only by the lazy panel (the main
                                // cause).
                        }
                    }
                }
                Spacer()
                Button { model.analysisController.cancel(blockId: blockId) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DSColor.textTertiary)
                }.buttonStyle(.plain)
            }
        }
    }

    private func failedRow(error: ClaudeError) -> some View {
        CardContainer(accentBorder: .red.opacity(0.35)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(error.userMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(DSColor.textPrimary)
                Button("Try again") { model.analysisController.retry(blockId: blockId) }
                    .font(.system(size: 11.5, weight: .medium))
            }
        }
    }
}
