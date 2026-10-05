import AppKit
import UniformTypeIdentifiers

/// Entry point of the export (SPEC §8): bridges the window state
/// (`DocumentModel`) and the three pure exporters
/// (`RewriteCopyExporter`/`RewritePDFExporter`/`RewriteDocxExporter`).
///
/// Deliberate separation (a test path with no save panel):
/// `document(for:scope:)` and the three exporters are pure and testable on
/// their own; only `exportPDF`/`exportDocx` (which open `NSSavePanel`) and
/// `copyFormatted` (which writes to `NSPasteboard`, parameterized for tests)
/// touch the outside. No test calls `exportPDF`/`exportDocx`: they would use
/// the real save panel.
@MainActor
enum RewriteExportController {
    /// Document ready for export, or `nil` if no structure is loaded yet (no
    /// `documento.json`, SPEC §5.2 "the structure arrives later"). Pure with
    /// respect to AppKit apart from the return type: no UI is opened here.
    static func document(for model: DocumentModel, scope: RewriteExportScope) -> RewriteExportDocument? {
        guard let documentRecord = model.documentRecord else { return nil }
        let analysis = model.analysisController.context?.analysis ?? AnalysisRecord()
        return RewriteExportModel.build(document: documentRecord, analysis: analysis, scope: scope, currentBlockId: model.currentFocusedBlockId, orphans: model.orphanBlocks)
    }

    /// SPEC §8.1 "Copy with Formatting": works even with no analyzed block
    /// (it exports only the header). It makes no sense to disable copying just
    /// because there is no content yet; the user sees right away what was
    /// copied by pasting it.
    static func copyFormatted(for model: DocumentModel, scope: RewriteExportScope, pasteboard: NSPasteboard = .general) {
        guard let document = document(for: model, scope: scope) else { return }
        RewriteCopyExporter.write(document, to: pasteboard, emphasizeMarkedTerms: WordTemplateSettings.emphasizeMarkedTerms())
    }

    static func exportPDF(for model: DocumentModel, scope: RewriteExportScope) {
        guard let document = document(for: model, scope: scope),
              let data = RewritePDFExporter.data(for: document, emphasizeMarkedTerms: WordTemplateSettings.emphasizeMarkedTerms()) else { return }
        presentSavePanel(suggestedName: fileName(for: document, extension: "pdf"), allowedContentTypes: [.pdf]) { url in
            try? data.write(to: url, options: .atomic)
        }
    }

    static func exportDocx(for model: DocumentModel, scope: RewriteExportScope) {
        guard let document = document(for: model, scope: scope) else { return }
        // The FIRST "Export to Word" asks for the template (or "Use Built-in
        // Template") instead of using it silently; not repeated once chosen.
        guard WordTemplateSettings.hasMadeTemplateChoice() || promptForTemplateChoice() else { return }
        // The template the user chose in Settings, or `nil` (built-in
        // template) if they explicitly chose to stay with it.
        let result = RewriteDocxExporter.export(
            for: document, templateDirectory: WordTemplateSettings.activeTemplateDirectory(),
            emphasizeMarkedTerms: WordTemplateSettings.emphasizeMarkedTerms()
        )
        let docxType = UTType(filenameExtension: "docx") ?? .data
        presentSavePanel(suggestedName: fileName(for: document, extension: "docx"), allowedContentTypes: [docxType]) { url in
            try? result.data.write(to: url, options: .atomic)
            reportFallbacksIfNeeded(result)
        }
    }

    /// Sheet for the first export with no template chosen: "Choose…" (opens
    /// the same panel as Settings, remembers the choice as
    /// `WordTemplateSettings.chooseTemplate` already does), "Use Built-in
    /// Template" (explicit, never asks again), "Cancel" (aborts the export,
    /// records no choice; asked again next time). Returns `true` if the export
    /// can proceed.
    @discardableResult
    private static func promptForTemplateChoice() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Choose a Word template"
        alert.informativeText = "No Word template has been chosen yet. Pick your own .docx template, or use the app's built-in template."
        alert.addButton(withTitle: "Choose Template…")
        alert.addButton(withTitle: "Use Built-in Template")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let url = SettingsPanels.chooseFile(startingAt: nil, allowedExtension: "docx") else { return false }
            do {
                try WordTemplateSettings.chooseTemplate(at: url)
                return true
            } catch {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Couldn't read this Word template"
                errorAlert.informativeText = "The file could not be read as a .docx archive: \(error)."
                errorAlert.alertStyle = .warning
                errorAlert.runModal()
                return false
            }
        case .alertSecondButtonReturn:
            WordTemplateSettings.chooseBuiltInTemplateExplicitly()
            return true
        default:
            return false
        }
    }

    /// Missing style -> nearest built-in style, reported: a simple notice
    /// after saving, only when there is really something to report. Never for
    /// an export with the built-in template (there is never a patch there),
    /// nor for a chosen template that has all the expected styles.
    private static func reportFallbacksIfNeeded(_ result: RewriteDocxExporter.Result) {
        guard result.customTemplateUnreadable || !result.fallbacksUsed.isEmpty else { return }
        let alert = NSAlert()
        if result.customTemplateUnreadable {
            alert.messageText = "Word template not readable"
            alert.informativeText = "The chosen Word template could not be read; the built-in default template was used instead. Choose the template again in Settings, or Restore default template."
        } else {
            let names = result.fallbacksUsed.map(\.rawValue).joined(separator: ", ")
            alert.messageText = "Some styles were not in the chosen template"
            alert.informativeText = "The built-in default was used instead for: \(names)."
        }
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Save panel (never called by tests)

    private static func presentSavePanel(suggestedName: String, allowedContentTypes: [UTType], completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = allowedContentTypes
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    private static func fileName(for document: RewriteExportDocument, extension ext: String) -> String {
        let base = document.header.documentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = sanitizeFileName(base.isEmpty ? "Rewrite" : base)
        return "\(sanitized).\(ext)"
    }

    /// Strips characters not allowed in a file name (SPEC §8, the document
    /// title is arbitrary, from any PDF: it may contain "/" or other
    /// separators).
    private static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }
}
