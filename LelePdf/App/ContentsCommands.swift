import SwiftUI

/// "Contents" menu ("Matching entries in the menu ... so they can be
/// found even without remembering them"): ⌘⌥1…4 on the current selection
/// in the PDF (single, or multiple with ⌘) create or change the level of
/// a T1-T4 entry in the manual contents, with the same effect as the
/// T1-T4 buttons of the selection bar (§5.7), the same shortcut, one
/// command per action.
///
/// Always enabled when there is a document (like "Sidebar"/"Right Panel"
/// in `DocumentCommands`): the action itself does nothing if there is no
/// text selection in the PDF (`DocumentModel.applyTocLevelShortcut`).
/// Entries disabled only on the basis of the selection state would
/// require observing `PDFView.currentSelection` from SwiftUI, which is
/// not `@Observable`, and would change this choice only slightly.
struct ContentsCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        CommandMenu("Contents") {
            ForEach(1 ... 4, id: \.self) { level in
                Button("Set as T\(level)") { model?.applyTocLevelShortcut(level: level) }
                    .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .option])
                    .disabled(model == nil)
            }
            Divider()
            // The same two commands are also in the "..." menu of the Contents tab
            // (`ChaptersSidebar`).
            Button("Show Only T1") { model?.showOnlyTopLevelTocEntries() }
                .disabled(model == nil)
            Button("Expand All") { model?.expandAllTocEntries() }
                .disabled(model == nil)
            Divider()
            // Same action as the control in the right panel and in the Contents tab
            // (`DocumentModel.requestSummaryGranularityChange`), which decides on its
            // own whether confirmation is needed. A menu item that shows the
            // current choice.
            Menu("Summarise By") {
                ForEach(SummaryGranularity.allCases) { granularity in
                    Button {
                        model?.requestSummaryGranularityChange(to: granularity)
                    } label: {
                        if granularity == model?.effectiveSummaryGranularity {
                            Label(granularity.label, systemImage: "checkmark")
                        } else {
                            Text(granularity.label)
                        }
                    }
                }
            }
            .disabled(model == nil)
        }
    }
}
