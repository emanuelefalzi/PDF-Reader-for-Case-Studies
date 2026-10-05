import Foundation

/// `UserDefaults` key for the default subject color of new documents
/// (SPEC §5.4 v2.6: "a default color for new documents in Settings"), same
/// pattern as `AnalysisModelPreference`
/// (`Analysis/AnalysisQueueState.swift`): a pure function over an injected
/// `UserDefaults`, never `.standard` read directly in tests.
///
/// `DocumentModel` captures a snapshot of it at open time and passes it to
/// the Store only if the document is new. Existing records do not change
/// when this preference changes.
enum DefaultColorThemePreference {
    static let defaultsKey = "defaultColorTheme"

    static func read(defaults: UserDefaults) -> MaterialHue {
        guard let raw = defaults.string(forKey: defaultsKey), let hue = MaterialHue(rawValue: raw) else {
            return .default
        }
        return hue
    }
}
