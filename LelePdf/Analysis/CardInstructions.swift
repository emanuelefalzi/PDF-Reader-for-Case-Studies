import Foundation

/// Fixed instructions of the card's "…" menu (SPEC §5.6 "Shorter", "More
/// detailed"): the text lives in `Resources/Prompts/card-instructions.json`
/// (instruction texts are kept in Resources, not in code), not written here.
/// In English, like all Claude prompts (`rewrite-block.md` quotes them
/// literally: "'shorter', 'more detailed'"), and passed as-is as `instruction`
/// to `AnalysisController.regenerate(blockId:instruction:)`.
enum CardInstructions {
    struct Texts: Codable, Sendable {
        var shorter: String
        var moreDetailed: String
    }

    /// Fallback values if the file is missing from the bundle (SPEC "never
    /// crash"): identical to the JSON's expected content, so a malformed
    /// bundle degrades silently instead of disabling the menu.
    static let fallback = Texts(shorter: "shorter", moreDetailed: "more detailed")

    static func load() -> Texts {
        guard let json = ClaudeResources.jsonText(named: "card-instructions"),
              let data = json.data(using: .utf8),
              let texts = try? JSONDecoder().decode(Texts.self, from: data) else { return fallback }
        return texts
    }
}
