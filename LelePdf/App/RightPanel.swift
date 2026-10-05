import SwiftUI
import AppKit

/// "Simplified rewrite" right panel (SPEC §5.6): header with path and the
/// "Follow the PDF" switch, body still a placeholder (arrives in M5), a
/// 72 pt bottom margin reserved for the future "Analyze the Next Block"
/// button.
struct RightPanel: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            let _ = PerfProbe.hit("swiftui.RightPanel.body")
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simplified rewrite")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(model.breadcrumb ?? "—")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DSColor.textSecondary)
                }
                Spacer()
                // "Export" in the right panel, next to "Follow the PDF" (SPEC §8).
                RewriteExportMenu()
                Toggle(isOn: $model.followPDF) {
                    Text("Follow the PDF").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
            .overlay(alignment: .bottom) {
                Rectangle().fill(DSColor.borderCard).frame(height: 0.5)
            }

            RewritePanel()
        }
        .frame(maxHeight: .infinity)
        .background(DSColor.rightPanelBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(DSColor.borderSoft).frame(width: 0.5)
        }
    }
}

// The actual divider is `PaneDivider` (`PaneDivider.swift`): shared
// with the sidebar's, so the two behave the same way (drag area,
// cursor, double click to reset, no animation delay while dragging).
