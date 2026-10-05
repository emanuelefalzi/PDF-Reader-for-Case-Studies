import SwiftUI

/// "Export" control of the right-hand panel (SPEC §8.4): scope (whole
/// document / current section only) plus the three formats. It lives in the
/// header of `RightPanel` (SPEC §5.1 "right-hand panel"), next to "Follow the
/// PDF". This view ALWAYS delegates to `RewriteExportController` and never
/// touches `NSSavePanel`/`NSPasteboard` on its own, so it stays identical in
/// the real app and in previews/layout tests.
struct RewriteExportMenu: View {
    @Environment(DocumentModel.self) private var model

    // The Export menu shows which template will be used: `@AppStorage`, not
    // a direct call to `WordTemplateSettings.templateMenuLabel()` inside
    // `body`, so the label updates right after "Choose…"/"Use Built-in
    // Template"/"Restore", the same principle as
    // `SettingsView.hasCustomWordTemplate`.
    @AppStorage(WordTemplateSettings.hasCustomTemplateDefaultsKey, store: AppRuntime.defaults)
    private var hasCustomWordTemplate = false
    @AppStorage(WordTemplateSettings.builtInTemplateChosenDefaultsKey, store: AppRuntime.defaults)
    private var builtInWordTemplateChosen = false

    var body: some View {
        Menu {
            scopeSection(.wholeDocument, title: "Whole Document")
            scopeSection(.currentSection, title: "Current Section")
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.system(size: 11))
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.documentRecord == nil)
    }

    private var templateLabel: String {
        WordTemplateSettings.templateMenuLabel(hasCustomTemplate: hasCustomWordTemplate, builtInTemplateChosenExplicitly: builtInWordTemplateChosen)
    }

    @ViewBuilder
    private func scopeSection(_ scope: RewriteExportScope, title: String) -> some View {
        Menu(title) {
            Button("Copy with Formatting") {
                RewriteExportController.copyFormatted(for: model, scope: scope)
            }
            Button("PDF…") {
                RewriteExportController.exportPDF(for: model, scope: scope)
            }
            Button("Word (.docx)… (\(templateLabel))") {
                RewriteExportController.exportDocx(for: model, scope: scope)
            }
        }
    }
}
