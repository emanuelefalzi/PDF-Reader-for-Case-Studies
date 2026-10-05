import Foundation
import Testing
@testable import LelePdf

/// The selected tab takes the place of `indexVisible` as the sidebar's
/// "remembered choice" (three tabs in a row, Pages/Contents/Map). Same scheme
/// as `PaneWidthStoreTests`: each test uses its own isolated `UserDefaults`
/// domain.
@Suite("SidebarPreferences")
struct SidebarPreferencesTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "com.emanuele.LelePdf.tests.sidebarprefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("no stored value: starts from Pages")
    func startsOnPagine() {
        let defaults = isolatedDefaults()
        #expect(SidebarPreferences.sidebarTab(defaults: defaults) == .pagine)
    }

    @Test("round trip of the selected tab")
    func sidebarTabRoundTrip() {
        let defaults = isolatedDefaults()
        SidebarPreferences.setSidebarTab(.indice, defaults: defaults)
        #expect(SidebarPreferences.sidebarTab(defaults: defaults) == .indice)
        SidebarPreferences.setSidebarTab(.mappa, defaults: defaults)
        #expect(SidebarPreferences.sidebarTab(defaults: defaults) == .mappa)
    }

    @Test("a stored value that is no longer valid starts from Pages instead of making the read fail")
    func invalidStoredValueFallsBackToPagine() {
        let defaults = isolatedDefaults()
        defaults.set("capitoli-vecchio-nome-rimosso", forKey: "sidebarSelectedTab")
        #expect(SidebarPreferences.sidebarTab(defaults: defaults) == .pagine)
    }

    @Test("a new window starts from the last saved tab (app default)")
    @MainActor
    func documentModelRestoresPersistedTab() throws {
        // `AppRuntime.defaults`: under XCTest it is already a per-process
        // isolated domain, never the user's real preferences.
        SidebarPreferences.setSidebarTab(.mappa, defaults: AppRuntime.defaults)

        let url = try StoreFixtures.makeTextPDF(
            text: "Documento vuoto solo per il test di ripristino della scheda sidebar.",
            fileName: "sidebartab-restore-\(UUID().uuidString).pdf"
        )
        let data = try Data(contentsOf: url)
        let fileDocument = PDFFileDocument(data: data, displayName: "sidebartab-restore-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: url))

        #expect(model.sidebarTab == .mappa)

        // Restores the shared domain to the default state so other tests do
        // not depend on execution order.
        SidebarPreferences.setSidebarTab(.pagine, defaults: AppRuntime.defaults)
    }
}
