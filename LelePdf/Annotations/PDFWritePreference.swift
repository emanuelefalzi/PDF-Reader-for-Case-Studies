import Foundation

/// Global setting for the write-to-PDF feature. A missing key always means
/// `false`: no PDF is modified by default.
enum PDFWritePreference {
    static let defaultsKey = "saveMarksAutomaticallyIntoPDF"

    static func isEnabled(defaults: UserDefaults = AppRuntime.defaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}
