import Foundation

/// Resolution of the rewrite instructions (SPEC §5.14 "Summary Lab"): the
/// system prompt used for the FIRST analysis of a block
/// (`AnalysisQueue+Execution.performAnalysis`) comes from a custom file in the
/// data folder if present, otherwise from the stock prompt in the bundle
/// (`Resources/Prompts/analysis.md`). The JSON schema (`analysis.schema.json`)
/// and the marker rules ALWAYS remain the bundled ones (prompts and schemas
/// live in Resources; the JSON schema and marker rules stay bundled and
/// unchanged, only the instruction text is customizable): only this text file
/// changes.
///
/// Deliberately narrow scope (SPEC §5.14 only mentions `Prompts/analysis.md`):
/// the targeted-regeneration prompt (`rewrite-block.md`, SPEC §7.6) is not
/// touched by this customization.
enum AnalysisInstructions {
    static let customFileName = "istruzioni-riscrittura.md"

    enum SaveError: LocalizedError {
        case emptyInstructions

        var errorDescription: String? {
            String(localized: "Instructions cannot be empty.")
        }
    }

    static func customFileURL(dataFolderURL: URL) -> URL {
        dataFolderURL.appendingPathComponent(customFileName)
    }

    /// Stock text (bundle), always available for "Restore the Original
    /// Instructions" in the Lab even when there is no custom file (yet).
    static func bundledText() -> String {
        ClaudeResources.promptText(named: "analysis") ?? ""
    }

    /// Non-editable constraints of the protocol with Claude. They stay in a
    /// resource separate from the code and are appended after the editable
    /// text: a custom prompt can change the style and density of the rewrite,
    /// but cannot remove the schema and markers.
    static func bundledContractText() -> String {
        ClaudeResources.promptText(named: "analysis-contract") ?? ""
    }

    static func hasCustom(dataFolderURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: customFileURL(dataFolderURL: dataFolderURL).path)
    }

    /// Effective text used by the pipeline (the custom file if present and
    /// readable, otherwise the stock one). Never throws: an unreadable or
    /// corrupt custom file falls back to the stock prompt instead of making
    /// the analysis fail.
    static func effectiveText(dataFolderURL: URL) -> String {
        let customURL = customFileURL(dataFolderURL: dataFolderURL)
        if let text = try? String(contentsOf: customURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return bundledText()
    }

    /// Effective system prompt: the editable instructions followed by the
    /// non-editable technical contract. `nil` if a required resource is
    /// missing from the bundle, so the call fails explicitly.
    static func systemPrompt(editableText: String) -> String? {
        let effective = editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? bundledText()
            : editableText
        let contract = bundledContractText()
        guard !effective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !contract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return effective + "\n\n" + contract
    }

    static func effectiveSystemPrompt(dataFolderURL: URL) -> String? {
        systemPrompt(editableText: effectiveText(dataFolderURL: dataFolderURL))
    }

    /// "Save as default" (SPEC §5.14): a direct atomic write, no debounce. It
    /// is an explicit user action in a dedicated window, not a constantly
    /// changing state like `analisi.json`.
    static func save(_ text: String, dataFolderURL: URL) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SaveError.emptyInstructions
        }
        try FileManager.default.createDirectory(at: dataFolderURL, withIntermediateDirectories: true)
        let url = customFileURL(dataFolderURL: dataFolderURL)
        let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try text.write(to: tmp, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// "Restore" (SPEC §5.14 "back to the stock ones"): deletes the custom
    /// file. Rewrites already saved do not change (it does not touch
    /// `analisi.json`).
    static func restore(dataFolderURL: URL) throws {
        let url = customFileURL(dataFolderURL: dataFolderURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// A warning (not a block) if the edited text no longer mentions the
    /// `{{mX|words}}` marker format (analysis.md point 12): without that
    /// explanation Claude stops marking terms in the rewrite, even though the
    /// JSON schema stays valid. An easy mistake for someone who does not
    /// program and does not see the schema.
    static func missingFormatWarning(_ text: String) -> String? {
        guard text.contains("{{") && text.contains("}}") else {
            return String(localized: "The instructions do not mention the {{mX|words}} format. The Lab still adds the technical marker contract automatically.")
        }
        return nil
    }
}
