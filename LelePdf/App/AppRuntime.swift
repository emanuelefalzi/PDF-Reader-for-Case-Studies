import Foundation

/// Process-level dependencies that must change under XCTest. The test
/// target is app-hosted and uses the same bundle id as the real app, so
/// reading `UserDefaults.standard` or accepting the default data folder
/// during a suite would mean reading the user's own preferences and
/// documents.
enum AppRuntime {
    static let isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Separate domain for the few components that really need preferences in
    /// tests. It is not the app's domain.
    // `UserDefaults` is declared `Sendable` (unchecked) in
    // `ClaudeCLILocator.swift` for the same reason documented there: no
    // `nonisolated(unsafe)` is needed here, that conformance is enough.
    static let defaults: UserDefaults = {
        guard isRunningUnderXCTest else { return .standard }
        let suite = "com.emanuele.LelePdf.tests.\(ProcessInfo.processInfo.processIdentifier)"
        return UserDefaults(suiteName: suite)!
    }()

    /// Mandatory fallback for an `xcodebuild test` launched directly, without
    /// the variables prepared by `scripts/test.sh`.
    static let xctestDataFolderURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "LelePdf-xctest-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
}
