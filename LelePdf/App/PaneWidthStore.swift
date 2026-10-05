import Foundation
import CoreGraphics

/// Remembered widths of the two resizable panels (SPEC §5.1): a harmless
/// interface preference, same principle as `AnnotationToolMemory`. Keys
/// `sidebarWidth`/`rightPanelWidth`, valid as app defaults for windows
/// opened later, not only for the window that did the dragging.
///
/// `defaults` defaults to `AppRuntime.defaults`, which under XCTest
/// already points to a per-process isolated domain: tests never touch
/// the user's real preferences.
enum PaneWidthStore {
    static let sidebarWidthKey = "sidebarWidth"
    static let rightPanelWidthKey = "rightPanelWidth"

    static func sidebarWidth(defaults: UserDefaults = AppRuntime.defaults) -> CGFloat? {
        let value = defaults.double(forKey: sidebarWidthKey)
        return value > 0 ? CGFloat(value) : nil
    }

    static func setSidebarWidth(_ width: CGFloat, defaults: UserDefaults = AppRuntime.defaults) {
        defaults.set(Double(width), forKey: sidebarWidthKey)
    }

    static func rightPanelWidth(defaults: UserDefaults = AppRuntime.defaults) -> CGFloat? {
        let value = defaults.double(forKey: rightPanelWidthKey)
        return value > 0 ? CGFloat(value) : nil
    }

    static func setRightPanelWidth(_ width: CGFloat, defaults: UserDefaults = AppRuntime.defaults) {
        defaults.set(Double(width), forKey: rightPanelWidthKey)
    }

    // MARK: - Visibility (⌘⌥1/⌘⌥2, with the state remembered): same
    // principle as the widths above and `SidebarPreferences.indexVisible`:
    // one `UserDefaults` key per app, not per document.

    private static let sidebarVisibleKey = "sidebarVisible"
    private static let rightPanelVisibleKey = "rightPanelVisible"

    /// `true` by default (like `SidebarPreferences.indexVisible`):
    /// `object(forKey:)` distinguishes "never saved" (first launch, or a clean
    /// test domain) from "saved false", which `bool(forKey:)` alone does not
    /// allow.
    static func sidebarVisible(defaults: UserDefaults = AppRuntime.defaults) -> Bool {
        guard defaults.object(forKey: sidebarVisibleKey) != nil else { return true }
        return defaults.bool(forKey: sidebarVisibleKey)
    }

    static func setSidebarVisible(_ visible: Bool, defaults: UserDefaults = AppRuntime.defaults) {
        defaults.set(visible, forKey: sidebarVisibleKey)
    }

    static func rightPanelVisible(defaults: UserDefaults = AppRuntime.defaults) -> Bool {
        guard defaults.object(forKey: rightPanelVisibleKey) != nil else { return true }
        return defaults.bool(forKey: rightPanelVisibleKey)
    }

    static func setRightPanelVisible(_ visible: Bool, defaults: UserDefaults = AppRuntime.defaults) {
        defaults.set(visible, forKey: rightPanelVisibleKey)
    }
}
