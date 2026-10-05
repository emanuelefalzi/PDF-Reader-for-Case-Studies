import SwiftUI

/// "Claude" section of Settings (SPEC §5.11, M10): CLI path
/// (auto-detected + manual override) and connection status.
struct ClaudeStatusSection: View {
    @AppStorage(ClaudeCLILocator.manualOverrideDefaultsKey, store: AppRuntime.defaults)
    private var manualCLIPath: String = ""

    @State private var detected: ClaudeCLILocator.Info?
    @State private var detectionFailed = false
    @State private var isDetecting = false

    var body: some View {
        Section {
            LabeledContent("Detected path") {
                Text(detectedPathText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DSColor.textSecondary)
                    .textSelection(.enabled)
            }
            LabeledContent("Manual path") {
                HStack(spacing: 6) {
                    TextField("Empty = automatic detection", text: $manualCLIPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit { redetect() }
                    Button("Choose…") {
                        if let url = SettingsPanels.chooseExecutable() {
                            manualCLIPath = url.path
                            redetect()
                        }
                    }
                }
            }
            HStack {
                Button("Detect again") { redetect() }
                if isDetecting { ProgressView().controlSize(.small).padding(.leading, 4) }
                Spacer()
            }
            if let detected, !detected.missingFlags.isEmpty {
                // M10 (SPEC §13 "CLI version/flags check at launch surfaced
                // clearly"): the same check `ClaudeStatusModel` already does for the
                // right panel's banner, but shown here plainly even when no document
                // is open.
                Label(
                    "Missing flags: \(detected.missingFlags.joined(separator: ", ")). Update the Claude CLI.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                .font(.caption)
            }
        } header: {
            Text("Claude CLI")
        }

        Section {
            statusRow
            Button("Verify") { Task { await ClaudeStatusModel.shared.refresh() } }
                .disabled(ClaudeStatusModel.shared.isRefreshing)
        } header: {
            Text("Status")
        }
        .task { redetect() }
    }

    private var detectedPathText: String {
        if let detected { return detected.versionString.isEmpty ? detected.path : "\(detected.path) (\(detected.versionString))" }
        return detectionFailed ? "Not found" : "Detecting…"
    }

    @ViewBuilder
    private var statusRow: some View {
        switch ClaudeStatusModel.shared.state {
        case .notFound:
            Label("CLI not found.", systemImage: "xmark.circle").foregroundStyle(.orange)
        case .notLoggedIn:
            VStack(alignment: .leading, spacing: 4) {
                Label("Not signed in.", systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                Text("Run \u{201c}claude auth login\u{201d} in Terminal, then Verify.")
                    .font(.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .loggedIn(let email, let plan):
            Label(statusLine(email: email, plan: plan), systemImage: "checkmark.circle").foregroundStyle(.green)
        }
    }

    private func statusLine(email: String?, plan: String?) -> String {
        let who = email ?? "unknown user"
        let planName = plan ?? "unknown plan"
        return "Signed in as \(who) (\(planName))"
    }

    private func redetect() {
        isDetecting = true
        Task {
            await ClaudeCLILocator.shared.resetCache()
            switch await ClaudeCLILocator.shared.info() {
            case .success(let info):
                detected = info
                detectionFailed = false
            case .failure:
                detected = nil
                detectionFailed = true
            }
            isDetecting = false
            await ClaudeStatusModel.shared.refresh()
        }
    }
}
