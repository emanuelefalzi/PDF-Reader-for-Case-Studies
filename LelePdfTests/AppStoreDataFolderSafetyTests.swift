import Foundation
import Testing
@testable import LelePdf

/// Regression found while investigating the right panel sometimes being
/// empty: `AppStore.shared` resolves the data folder ONLY ONCE, lazily. The
/// scripts set `TEST_RUNNER_LELEPDF_DATA_DIR`, but a direct `xcodebuild
/// test` does not: production code must therefore recognize XCTest before
/// reading UserDefaults or choosing `~/Documents/LelePdf`.
///
/// This test is a permanent safety net: it verifies that, for WHATEVER
/// touched `AppStore.shared` before it in this process, the resolved folder
/// is never the author's real one — since the resolution happens only once
/// and stays fixed for the whole process, a check at any point of the run
/// holds for the entire run.
@Suite("AppStore · data folder safety in tests")
struct AppStoreDataFolderSafetyTests {
    @Test("AppStore.shared never resolves to the real data folder during tests")
    func appStoreNeverResolvesToRealDocumentsFolder() async throws {
        let realDataFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LelePdf", isDirectory: true)
            .standardizedFileURL
        let resolved = await AppStore.shared.dataFolderURL.standardizedFileURL

        #expect(resolved != realDataFolder, "AppStore.shared resolved the REAL data folder (\(realDataFolder.path)): LELEPDF_DATA_DIR did not reach the test process — see scripts/test.sh")

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].standardizedFileURL
        #expect(!resolved.path.hasPrefix(desktop.path), "AppStore.shared resolved a data folder under ~/Desktop: \(resolved.path)")
    }

    @Test("a temporary override stays valid under XCTest")
    func temporaryOverrideIsAccepted() throws {
        let explicit = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfResolveDataFolderTest-\(UUID().uuidString)")
        let resolved = DocumentStore.resolveDataFolder(override: explicit)
        #expect(resolved == explicit)
    }

    @Test("XCTest explicitly rejects overrides under Desktop or Documents")
    func protectedFolderOverridesAreRejected() throws {
        #expect(AppRuntime.isRunningUnderXCTest)
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LelePdf-test", isDirectory: true)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LelePdf", isDirectory: true)

        #expect(DocumentStore.resolveDataFolder(override: desktop) == AppRuntime.xctestDataFolderURL)
        #expect(DocumentStore.resolveDataFolder(override: documents) == AppRuntime.xctestDataFolderURL)
    }
}
