import Foundation

/// `UserDefaults` key for the default summary granularity of new
/// documents ("a default in Settings"), same pattern as
/// `DefaultColorThemePreference` (`Settings/ColorThemePreference.swift`): a
/// pure function over an injected `UserDefaults`, never `.standard` read
/// directly in tests.
///
/// `DocumentModel` captures a snapshot of it at open time and passes it to
/// the Store only if the document is NEW (`DocumentStore.registerDocument`):
/// existing records stay `nil` (the previous behavior) until the user
/// explicitly picks a granularity for that document.
enum DefaultSummaryGranularityPreference {
    static let defaultsKey = "defaultSummaryGranularity"

    /// The factory default is `heading3`, the granularity numerically closest
    /// to the previous behavior (section = lowest heading level available), so
    /// a new document that never touches this preference behaves, in
    /// practice, as before.
    static func read(defaults: UserDefaults) -> SummaryGranularity {
        guard let raw = defaults.string(forKey: defaultsKey), let value = SummaryGranularity(rawValue: raw) else {
            return .heading3
        }
        return value
    }
}
