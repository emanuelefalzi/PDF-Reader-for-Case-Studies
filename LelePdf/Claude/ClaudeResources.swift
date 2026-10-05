import Foundation

/// Loads prompts and schemas from `LelePdf/Resources/` (prompts and schemas
/// live in `Resources/`, not in code). The two folder references in the
/// project put the files in `Contents/Resources/Prompts/*.md` and
/// `Contents/Resources/Schemas/*.json` in the app bundle.
enum ClaudeResources {
    static func promptText(named name: String) -> String? {
        text(name: name, extension: "md", subdirectory: "Prompts")
    }

    /// Schema files are named `<name>.schema.json` (e.g. `toc.schema.json`,
    /// `analysis.schema.json`), not `<name>.json`.
    static func schemaText(named name: String) -> String? {
        text(name: "\(name).schema", extension: "json", subdirectory: "Schemas")
    }

    /// Non-prompt configuration file in `Resources/Prompts/` (prompts and
    /// schemas live in Resources): used for the fixed texts of the card's "…"
    /// menu ("Shorter"/"More detailed", see `CardInstructions.swift`). Not a
    /// real Claude prompt or schema, but still text that must not be written
    /// inside the code.
    static func jsonText(named name: String) -> String? {
        text(name: name, extension: "json", subdirectory: "Prompts")
    }

    private static func text(name: String, extension ext: String, subdirectory: String) -> String? {
        let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
            ?? Bundle.main.url(forResource: name, withExtension: ext)
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
