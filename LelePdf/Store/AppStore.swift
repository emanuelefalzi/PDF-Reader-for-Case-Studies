import Foundation

/// The shared `DocumentStore` instance for the whole app (SPEC §6.3: "a
/// single instance ... per data folder"). The folder is resolved from
/// `LELEPDF_DATA_DIR`, then from `UserDefaults.dataFolderPath` (Settings,
/// M10), then from `~/Documents/LelePdf` (SPEC §8, §5.11). Under XCTest the
/// resolution is instead forced outside Desktop/Documents even when the
/// suite is launched with a direct `xcodebuild test`, without the scripts.
enum AppStore {
    static let shared = DocumentStore()
}
