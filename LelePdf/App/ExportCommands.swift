import SwiftUI

/// File › Export menu (SPEC §5.1 point 8 "File (Open ⌘O, Close ⌘W,
/// Export)"): the same control as the right panel (`RewriteExportMenu`),
/// here as a menu item. No shortcut (SPEC assigns none, and three formats
/// x two scopes would make a single key combination ambiguous).
struct ExportCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    // Same label as the right panel (`RewriteExportMenu`), here in the File
    // menu; see there for the reason for `@AppStorage`.
    @AppStorage(WordTemplateSettings.hasCustomTemplateDefaultsKey, store: AppRuntime.defaults)
    private var hasCustomWordTemplate = false
    @AppStorage(WordTemplateSettings.builtInTemplateChosenDefaultsKey, store: AppRuntime.defaults)
    private var builtInWordTemplateChosen = false

    private var templateLabel: String {
        WordTemplateSettings.templateMenuLabel(hasCustomTemplate: hasCustomWordTemplate, builtInTemplateChosenExplicitly: builtInWordTemplateChosen)
    }

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Menu("Export") {
                Menu("Whole Document") {
                    exportButtons(scope: .wholeDocument)
                }
                Menu("Current Section") {
                    exportButtons(scope: .currentSection)
                }
            }
            .disabled(model?.documentRecord == nil)
        }
    }

    @ViewBuilder
    private func exportButtons(scope: RewriteExportScope) -> some View {
        Button("Copy with Formatting") {
            guard let model else { return }
            RewriteExportController.copyFormatted(for: model, scope: scope)
        }
        Button("PDF…") {
            guard let model else { return }
            RewriteExportController.exportPDF(for: model, scope: scope)
        }
        Button("Word (.docx)… (\(templateLabel))") {
            guard let model else { return }
            RewriteExportController.exportDocx(for: model, scope: scope)
        }
    }
}
