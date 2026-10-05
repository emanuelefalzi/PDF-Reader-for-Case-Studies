import SwiftUI

/// Content of the unified toolbar (SPEC §5.1). No Actions menu or snapshot
/// button (point 2); the central pill stays hidden until an analysis is
/// running (point 7, arrives in M5); the subtitle is just "N pages"
/// (point 1).
struct WindowToolbarContent: ToolbarContent {
    @Environment(DocumentModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .help("Sidebar (⌘⇧1)")
        }

        ToolbarItem(placement: .navigation) {
            Button {
                model.toggleRightPanel()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help("Right panel (⌘⇧2)")
        }

        ToolbarItem(placement: .navigation) {
            // Fixed maximum width: without a limit, a long file name overflows the
            // toolbar and macOS moves the search field into the ">>" menu, making it
            // unreachable at the window's minimum width (1040 pt).
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(model.pageCount) pages")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: DSMetrics.toolbarTitleMaxWidth, alignment: .leading)
        }

        if let info = model.analysisPillInfo {
            ToolbarItem(placement: .principal) {
                AnalysisPill(info: info)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            // SPEC §5.13: Preview's "Markup" button (pen-tip icon): ⇧⌘A,
            // `AnnotationCommands.swift`.
            Button {
                model.annotationController.barVisible.toggle()
            } label: {
                Image(systemName: "pencil.tip.crop.circle")
            }
            .help(model.annotationController.barVisible ? "Hide the annotation toolbar (⇧⌘A)" : "Show the annotation toolbar (⇧⌘A)")
        }

        ToolbarItem(placement: .primaryAction) {
            SearchBar()
        }
    }
}

/// Progress pill (SPEC §5.1 point 7, §5.5): hidden until some block has
/// been analyzed or an analysis is running (`model.analysisPillInfo ==
/// nil`); otherwise static progress "12 of 58 blocks" with a thin bar, or
/// during an analysis a spinner + "Analysis 3.2 · 12 of 58 blocks" + bar.
/// Compact even at 1040 pt (SPEC M5b deliverable 4): no free text, only
/// numbers and a 60 pt bar.
private struct AnalysisPill: View {
    let info: DocumentModel.AnalysisPillInfo

    private var fraction: Double {
        info.total > 0 ? Double(info.analyzed) / Double(info.total) : 0
    }

    var body: some View {
        HStack(spacing: 7) {
            if info.isRunning {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DSColor.borderSoft).frame(height: 3)
                        Capsule().fill(DSColor.accent).frame(width: geometry.size.width * fraction, height: 3)
                    }
                }
                .frame(width: 60, height: 3)
            }
        }
        .padding(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
        .background(DSColor.pillBackground)
        .clipShape(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusPill))
        .overlay(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusPill).stroke(DSColor.borderSoft, lineWidth: 0.5))
    }

    private var label: String {
        if info.isRunning, let runningLabel = info.runningLabel {
            return String(localized: "Analysis \(runningLabel) \u{b7} \(info.analyzed) of \(info.total)")
        }
        return String(localized: "\(info.analyzed) of \(info.total) blocks")
    }
}
