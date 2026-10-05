import SwiftUI

/// Banners at the top of the right-hand panel (SPEC §5.12, §5.5 "Errors"):
/// CLI missing / not signed in, usage limit reached.
extension RewritePanel {
    @ViewBuilder
    var banners: some View {
        switch ClaudeStatusModel.shared.state {
        case .notFound:
            banner(icon: "exclamationmark.triangle", text: "Claude CLI not found. Install it or set the path in Settings.", action: verifyAction)
        case .notLoggedIn:
            banner(icon: "person.crop.circle.badge.exclamationmark", text: "Not signed in to Claude. Run \u{201c}claude auth login\u{201d} in Terminal.", action: verifyAction)
        case .error(let message):
            banner(icon: "exclamationmark.triangle", text: message, action: verifyAction)
        case .loggedIn:
            EmptyView()
        }
        if let resetAt = model.analysisController.queue.usageLimitResetAt {
            usageLimitBanner(resetAt: resetAt)
        }
    }

    private func banner(icon: String, text: String, action: (String, () -> Void)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon).foregroundStyle(.orange)
                Text(text).font(.system(size: 11.5)).foregroundStyle(DSColor.textPrimary)
            }
            Button(action.0, action: action.1).font(.system(size: 11, weight: .medium))
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard))
    }

    private var verifyAction: (String, () -> Void) {
        ("Verify", { Task { await ClaudeStatusModel.shared.refresh() } })
    }

    private func usageLimitBanner(resetAt: Date?) -> some View {
        let message: String
        if let resetAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            formatter.locale = Locale(identifier: "en_US")
            message = "Usage limit reached. Try again after \(formatter.string(from: resetAt))."
        } else {
            message = "Usage limit reached."
        }
        return banner(icon: "hourglass", text: message, action: ("Try again", {
            if let blockId = model.analysisController.queue.failures.first(where: { if case .usageLimit = $0.value { true } else { false } })?.key {
                model.analysisController.retry(blockId: blockId)
            } else {
                model.analysisController.analyzeNext(fromReadingPosition: model.analysisController.readingPositionBlock(currentPageIndex: model.currentPageIndex))
            }
        }))
    }
}
