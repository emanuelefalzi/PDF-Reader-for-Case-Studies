import Foundation

/// Sidebar interface preferences remembered per app, not per document
/// (restoring the sidebar with three tabs in a row, Pages/Contents/Map,
/// requested verbatim by the user after trying the previous version). Before that, this key
/// remembered `indexVisible`, showing/hiding an always-present contents
/// panel above a two-entry segmented control, but that panel no longer
/// exists: the "remembered choice" is now simply which of the three tabs
/// was selected. Same principle as `PaneWidthStore`: one `UserDefaults`
/// key, valid as an app default for windows opened later, not only for
/// the one that changed the preference.
///
/// `defaults` defaults to `AppRuntime.defaults`, which under XCTest
/// already points to a per-process isolated domain: tests never touch
/// the user's real preferences.
enum SidebarPreferences {
    private static let sidebarTabKey = "sidebarSelectedTab"

    /// `.pagine` by default: a `UserDefaults` without this key (first
    /// launch, or a clean test domain) or with a value that is no longer valid
    /// (`rawValue` of a tab removed in an earlier build) starts again from
    /// the first tab instead of failing the read.
    static func sidebarTab(defaults: UserDefaults = AppRuntime.defaults) -> SidebarTab {
        guard let raw = defaults.string(forKey: sidebarTabKey), let tab = SidebarTab(rawValue: raw) else { return .pagine }
        return tab
    }

    static func setSidebarTab(_ tab: SidebarTab, defaults: UserDefaults = AppRuntime.defaults) {
        defaults.set(tab.rawValue, forKey: sidebarTabKey)
    }
}
