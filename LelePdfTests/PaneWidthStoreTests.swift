import Foundation
import Testing
@testable import LelePdf

/// Remembered widths of the two panels. Each test uses its own isolated
/// `UserDefaults` domain (not `AppRuntime.defaults`, which under XCTest is
/// already isolated per process). Here we also want to avoid sharing state
/// between tests of the same process, and to prove explicitly that the type
/// never touches the real preferences when given a dedicated domain: tests
/// must never write to the real preferences.
@Suite("PaneWidthStore")
struct PaneWidthStoreTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "com.emanuele.LelePdf.tests.panewidth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("no saved value: nil")
    func startsEmpty() {
        let defaults = isolatedDefaults()
        #expect(PaneWidthStore.sidebarWidth(defaults: defaults) == nil)
        #expect(PaneWidthStore.rightPanelWidth(defaults: defaults) == nil)
    }

    @Test("round trip of the sidebar width")
    func sidebarRoundTrip() {
        let defaults = isolatedDefaults()
        PaneWidthStore.setSidebarWidth(310, defaults: defaults)
        #expect(PaneWidthStore.sidebarWidth(defaults: defaults) == 310)
        // Literal key the feature requires: `sidebarWidth`.
        #expect(defaults.double(forKey: "sidebarWidth") == 310)
    }

    @Test("round trip of the right panel width")
    func rightPanelRoundTrip() {
        let defaults = isolatedDefaults()
        PaneWidthStore.setRightPanelWidth(450, defaults: defaults)
        #expect(PaneWidthStore.rightPanelWidth(defaults: defaults) == 450)
        // Literal key the feature requires: `rightPanelWidth`.
        #expect(defaults.double(forKey: "rightPanelWidth") == 450)
    }

    @Test("a new window starts from the last saved width (app default)")
    @MainActor
    func documentModelRestoresPersistedWidths() throws {
        // `AppRuntime.defaults`: under XCTest it is already an isolated domain
        // per process (see `AppRuntime.swift`), never the user's real
        // preferences. That is why `DocumentModel`/`PaneWidthStore` can use it
        // by default here too, without having to inject it by hand.
        PaneWidthStore.setSidebarWidth(322, defaults: AppRuntime.defaults)
        PaneWidthStore.setRightPanelWidth(410, defaults: AppRuntime.defaults)

        let url = try StoreFixtures.makeTextPDF(
            text: "Documento vuoto solo per il test di ripristino larghezze.",
            fileName: "panewidth-restore-\(UUID().uuidString).pdf"
        )
        let data = try Data(contentsOf: url)
        let fileDocument = PDFFileDocument(data: data, displayName: "panewidth-restore-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: url))

        #expect(model.sidebarWidth == 322)
        #expect(model.rightPanelWidth == 410)
    }
}
