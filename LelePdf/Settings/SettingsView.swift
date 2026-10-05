import AppKit
import SwiftUI

/// Settings scene (SPEC §5.11, ⌘,, M10): data folder,
/// CLI, models, chat budget, Claude status. A single `Form` (no tabs:
/// there are few entries), consistent with the app's other windows, no
/// third-party SwiftUI components.
struct SettingsView: View {
    @AppStorage(DocumentStore.dataFolderDefaultsKey, store: AppRuntime.defaults)
    private var dataFolderPath: String = ""

    @AppStorage(AnalysisModelPreference.defaultsKey, store: AppRuntime.defaults)
    private var analysisModelRaw: String = ClaudeModel.sonnet.rawValue

    @AppStorage(ChatPreferences.modelDefaultsKey, store: AppRuntime.defaults)
    private var chatModelRaw: String = ClaudeModel.sonnet.rawValue

    @AppStorage(ChatPreferences.budgetDefaultsKey, store: AppRuntime.defaults)
    private var chatBudget: Int = 80_000

    @AppStorage(DefaultColorThemePreference.defaultsKey, store: AppRuntime.defaults)
    private var defaultColorThemeRaw: String = MaterialHue.default.rawValue

    // Default for NEW documents only: an existing document does not change
    // on its own (`DefaultSummaryGranularityPreference`).
    @AppStorage(DefaultSummaryGranularityPreference.defaultsKey, store: AppRuntime.defaults)
    private var defaultSummaryGranularityRaw: String = SummaryGranularity.heading3.rawValue

    @AppStorage(PDFWritePreference.defaultsKey, store: AppRuntime.defaults)
    private var saveAutomaticallyIntoPDF = false

    // Re-reads the `WordTemplateSettings` key instead of calling
    // `hasCustomTemplate()` inside `body`: same principle as `dataFolderPath`
    // above, so the "Restore" button appears/disappears immediately.
    @AppStorage(WordTemplateSettings.hasCustomTemplateDefaultsKey, store: AppRuntime.defaults)
    private var hasCustomWordTemplate = false

    // Off by default.
    @AppStorage(WordTemplateSettings.emphasizeMarkedTermsDefaultsKey, store: AppRuntime.defaults)
    private var emphasizeMarkedTerms = false

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                LabeledContent("Data folder") {
                    Text(displayedDataFolderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DSColor.textSecondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…") {
                        if let url = SettingsPanels.chooseFolder(startingAt: currentDataFolderURL) {
                            dataFolderPath = url.path
                        }
                    }
                    if !dataFolderPath.isEmpty {
                        Button("Default") { dataFolderPath = "" }
                    }
                }
                Text("Applies to PDFs opened from now on: ones already open stay in the folder they were read from.")
                    .font(.caption)
                    .foregroundStyle(DSColor.textSecondary)
            } header: {
                Text("Data")
            }

            Section {
                Picker("Analysis", selection: $analysisModelRaw) {
                    Text("Sonnet").tag(ClaudeModel.sonnet.rawValue)
                    Text("Opus").tag(ClaudeModel.opus.rawValue)
                }
                Picker("Chat", selection: $chatModelRaw) {
                    Text("Sonnet").tag(ClaudeModel.sonnet.rawValue)
                    Text("Opus").tag(ClaudeModel.opus.rawValue)
                }
                LabeledContent("Chat context budget") {
                    TextField("Tokens", value: $chatBudget, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Text("Model changes apply to windows opened from now on.")
                    .font(.caption)
                    .foregroundStyle(DSColor.textSecondary)
            } header: {
                Text("Models")
            }

            Section {
                Picker("Subject Color", selection: $defaultColorThemeRaw) {
                    ForEach(MaterialHue.allCases) { hue in
                        Text(hue.label).tag(hue.rawValue)
                    }
                }
                Text("Default color for new documents (SPEC §5.4): can be changed per document from the sidebar legend.")
                    .font(.caption)
                    .foregroundStyle(DSColor.textSecondary)
            } header: {
                Text("Subject Color")
            }

            Section {
                Picker("Summarise by", selection: $defaultSummaryGranularityRaw) {
                    ForEach(SummaryGranularity.allCases) { granularity in
                        Text(granularity.label).tag(granularity.rawValue)
                    }
                }
                Text("Default block granularity for new documents: per paragraph, per Heading 3/2, or per whole chapter. Can be changed per document from the Contents tab or the Contents menu; existing documents are not changed.")
                    .font(.caption)
                    .foregroundStyle(DSColor.textSecondary)
            } header: {
                Text("Summary Granularity")
            }

            Section {
                Toggle("Save automatically into the PDF", isOn: $saveAutomaticallyIntoPDF)
                Text("Off by default. When on, marks and annotations are written into the original PDF with a backup copy next to the file.")
                    .font(.caption)
                    .foregroundStyle(DSColor.textSecondary)
            } header: {
                Text("Marks in the PDF")
            }

            Section {
                LabeledContent("Word template for export") {
                    Text(hasCustomWordTemplate ? "Custom template chosen" : "Built-in default template")
                        .font(.system(size: 11))
                        .foregroundStyle(DSColor.textSecondary)
                }
                HStack {
                    Button("Choose…") { chooseWordTemplate() }
                    if hasCustomWordTemplate {
                        Button("Restore default template") {
                            WordTemplateSettings.restoreDefaultTemplate()
                        }
                    }
                }
                Text("The exported .docx uses this template's styles (Heading1-3, Puntoelenco, Sub-puntoelenco, Nota, Formula, Conseguenza, Spiegazionebullet, grassotitoli). A missing style falls back to the built-in default and is reported after export.")
                    .font(.caption)
                    .foregroundStyle(DSColor.textSecondary)
                Toggle("Emphasise marked terms", isOn: $emphasizeMarkedTerms)
                Text("Off by default (SPEC §5.4 marks are not exported as bold text). When on, a marked term uses the template's character style if it has one, in Word, PDF and Copy with Formatting.")
                    .font(.caption)
                    .foregroundStyle(DSColor.textSecondary)
            } header: {
                Text("Word template")
            }

            ClaudeStatusSection()

            Section {
                Button("Open the Summary Lab…") {
                    openWindow(id: LaboratorioView.windowID)
                }
                Text("To change on your own how Claude rewrites blocks, with the effect visible right away on a block of the open PDF.")
                    .font(.caption)
                    .foregroundStyle(DSColor.textSecondary)
            } header: {
                Text("Summary Lab")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Choose...": copies the chosen `.docx` (unpacked) into Application
    /// Support once (`WordTemplateSettings`); after this it no longer reads
    /// the Desktop on every export.
    private func chooseWordTemplate() {
        guard let url = SettingsPanels.chooseFile(startingAt: nil, allowedExtension: "docx") else { return }
        do {
            try WordTemplateSettings.chooseTemplate(at: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't read this Word template"
            alert.informativeText = "The file could not be read as a .docx archive: \(error)."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private var currentDataFolderURL: URL? {
        dataFolderPath.isEmpty ? nil : URL(fileURLWithPath: dataFolderPath, isDirectory: true)
    }

    private var displayedDataFolderPath: String {
        dataFolderPath.isEmpty ? DocumentStore.resolveDataFolder(override: nil).path + "  (default)" : dataFolderPath
    }
}
