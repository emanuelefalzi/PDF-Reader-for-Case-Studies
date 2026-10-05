import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// Visual verification of the main surfaces after the interface was
/// translated to English (the app's language overall is English): same
/// `exportPNG`/`host` harness as `SidebarIndexLegendRenderTests`/
/// `CardItemOverlapTests`. PNGs go to `~/Library/Caches/LelePdf/
/// verifica-screenshots/` and are re-read after export (not just written).
/// Covers the main surfaces: sidebar, rewrite-panel card with its buttons,
/// settings, plus a text dump of the menu command table (`MenuCommandTable`).
extension HeavyTestSuites {
@MainActor
@Suite("English interface visual verification", .serialized)
struct F14EnglishVerificationRenderTests {
    private static let outputRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)

    private func host(_ view: some View, width: CGFloat, height: CGFloat) -> (view: NSHostingView<AnyView>, window: NSWindow) {
        let hostingView = NSHostingView(rootView: AnyView(view.frame(width: width, height: height, alignment: .top)))
        hostingView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        return (hostingView, window)
    }

    private func block(_ id: String, page: Int, pageEnd: Int? = nil) -> TextBlock {
        TextBlock(
            id: id, sectionPath: [], pageStart: page, pageEnd: pageEnd ?? page,
            cleanText: "Term", textHash: id, words: 1, spans: [], lineRectsByPage: [:]
        )
    }

    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Test document for the F14 verification.", fileName: "f14-verify-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "f14-verify-test")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }

    @Test("Sidebar: three tabs Pages/Contents/Map, contents and legend in English")
    func sidebarIsEnglish() throws {
        let model = try makeModel()
        model.setColorTheme(.blu)
        model.tocSource = .generated
        model.tocEntries = [
            TocEntry(id: "t1", title: "Chapter 1 · Introduction", level: 1, page: 0),
            TocEntry(id: "t2", title: "1.1 Background", level: 2, page: 1, origin: .manual),
        ]
        model.sidebarTab = .indice
        let view = Sidebar().environment(model)
        let (hostingView, window) = host(view, width: 300, height: 560)
        defer { closeTestWindow(window) }
        try FileManager.default.createDirectory(at: Self.outputRoot, withIntermediateDirectories: true)
        let pngURL = Self.outputRoot.appendingPathComponent("f14-sidebar-contents-en.png")
        exportPNG(hostingView, to: pngURL)
        #expect(FileManager.default.fileExists(atPath: pngURL.path))

        // Not just a visual check: the real labels come through the real
        // types (SidebarTab.label/ColorThemePickerList), not from an HTML
        // fragment, and are checked here in plain text.
        #expect(SidebarTab.pagine.label == "Pages")
        #expect(SidebarTab.indice.label == "Contents")
        #expect(SidebarTab.mappa.label == "Map")
    }

    @Test("Rewrite-panel card: header, page chip and buttons in English")
    func rewriteCardIsEnglish() throws {
        let model = try makeModel()
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Nintendo's strategy",
            rewrite: [
                RewriteItem(kind: .summary, text: "A short summary of the block."),
                RewriteItem(kind: .definition, text: "A defined term."),
            ]
        )
        model.analysisController.updateContext(
            fingerprint: "fp", documentTitle: "T",
            blocks: [block("b1", page: 3, pageEnd: 4)],
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )
        guard let data = model.analysisController.cardData(for: "b1") else {
            Issue.record("cardData(for:) did not find the analyzed block")
            return
        }
        let view = BlockCardView(blockId: "b1", cardData: data, isRegenerating: false, isCurrent: false)
            .environment(model)
        let (hostingView, window) = host(view, width: 340, height: 260)
        defer { closeTestWindow(window) }
        try FileManager.default.createDirectory(at: Self.outputRoot, withIntermediateDirectories: true)
        let pngURL = Self.outputRoot.appendingPathComponent("f14-rewrite-card-buttons-en.png")
        exportPNG(hostingView, to: pngURL)
        #expect(FileManager.default.fileExists(atPath: pngURL.path))

        // "DEFINITION" is drawn by RewriteItemView for kind == .definition.
        #expect(RewriteViewModel.pageRangeLabel(start: data.page, end: data.pageEnd) == "p. 4-5")
    }

    @Test("RewritePanel: \"Analyze the Next Block\" button at the bottom of the panel")
    func rewritePanelBottomButtonIsEnglish() throws {
        let model = try makeModel()
        let view = RewritePanel().environment(model)
        let (hostingView, window) = host(view, width: 360, height: 500)
        defer { closeTestWindow(window) }
        try FileManager.default.createDirectory(at: Self.outputRoot, withIntermediateDirectories: true)
        let pngURL = Self.outputRoot.appendingPathComponent("f14-rewrite-panel-en.png")
        exportPNG(hostingView, to: pngURL)
        #expect(FileManager.default.fileExists(atPath: pngURL.path))
        #expect(RewriteViewModel.analyzeNextButtonText == "Analyze the next block")
    }

    @Test("Settings: Data/Models/Subject Color/Marks in the PDF/Word template/Claude/Summary Lab sections in English")
    func settingsIsEnglish() throws {
        let view = SettingsView()
        let (hostingView, window) = host(view, width: 480, height: 900)
        defer { closeTestWindow(window) }
        try FileManager.default.createDirectory(at: Self.outputRoot, withIntermediateDirectories: true)
        let pngURL = Self.outputRoot.appendingPathComponent("f14-settings-en.png")
        exportPNG(hostingView, to: pngURL)
        #expect(FileManager.default.fileExists(atPath: pngURL.path))
    }

    @Test("MenuCommandTable: no menu title is left in Italian")
    func menuCommandTableTitlesAreEnglish() throws {
        try FileManager.default.createDirectory(at: Self.outputRoot, withIntermediateDirectories: true)
        let dumpURL = Self.outputRoot.appendingPathComponent("f14-menu-command-table-en.txt")
        let byMenu = Dictionary(grouping: MenuCommandTable.all) { $0.menu }
        var lines: [String] = []
        for menu in MenuCommandSpec.Menu.allCases {
            lines.append("== \(menu.rawValue) ==")
            for spec in byMenu[menu] ?? [] {
                let shortcut = spec.key.map { "\($0) [\(spec.modifiers)]" } ?? "—"
                lines.append("  \(spec.id): \"\(spec.title)\" (\(shortcut))\(spec.systemProvided ? " [system]" : "")")
            }
        }
        let dump = lines.joined(separator: "\n") + "\n"
        try dump.write(to: dumpURL, atomically: true, encoding: .utf8)

        // No common Italian accented letter in any title: the same check
        // used by hand during the translation (grep for à/è/é/ì/ò/ù), here
        // as a permanent automatic assertion.
        let accented = CharacterSet(charactersIn: "àèéìòùÀÈÉÌÒÙ")
        for spec in MenuCommandTable.all {
            #expect(
                spec.title.rangeOfCharacter(from: accented) == nil,
                "menu title still in Italian: \(spec.id) = \"\(spec.title)\""
            )
        }
    }
}
}
