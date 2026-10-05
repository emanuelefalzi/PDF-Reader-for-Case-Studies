import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// F12: live check that ⌘F moves the window's REAL focus (not just
/// `@FocusState`, the actual cause found at the time) and that the field
/// responds to ⏎/Esc.
///
/// No `window.makeKeyAndOrderFront`/`NSWindow.sendEvent`/`NSApp.sendEvent`
/// here (see the comment at the top of `InlineLineEditingTests.swift`: a
/// window ORDERED onto the screen proved unstable in this app-hosted test
/// host, with very long or hung runs measured twice). Calls to
/// `SearchFieldView.Coordinator.control(_:textView:doCommandBy:)` are direct
/// (the same method AppKit would call during editing of the field, with the
/// same selector a real ⏎/Esc would produce): it exercises the REAL code,
/// only without the `NSApplication.sendEvent` round trip.
/// **Known limit, stated honestly** (the same principle chosen elsewhere in
/// this codebase): the ⏎/⇧⏎ distinction in the production view reads
/// `NSApp.currentEvent` (populated ONLY by a real `NSApplication.sendEvent`
/// round trip, which a direct call does not go through). It cannot be
/// reproduced reliably in this test host, so it is not automated here: ⇧⏎ →
/// previous still has to be checked live by the author (⏎ → next, the most
/// common path, is verified below).
extension HeavyTestSuites {
@MainActor
@Suite("F12: real focus of the search field (⌘F/⏎/Esc)", .serialized)
struct SearchFieldFocusTests {
    private func block(_ id: String, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: 0, pageEnd: 0, cleanText: text, textHash: id, words: text.split(separator: " ").count, spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    private struct Scene {
        let model: DocumentModel
        let window: NSWindow
        let hostingView: NSHostingView<AnyView>
    }

    /// PDF with the same word twice, for a realistic "2 of 2" case plus a
    /// right-panel block that also contains it.
    private func makeScene() throws -> Scene {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "La parola faro compare due volte: un faro sulla scogliera.", fileName: "search-focus-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "search-focus-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, rewrite: [RewriteItem(kind: .paragraph, text: "Anche la scheda riassunta parla del faro.")], claudeRewrite: [])
        model.analysisController.updateContext(fingerprint: "fp-search-focus-\(UUID().uuidString)", documentTitle: "T", blocks: [block("b1", text: "faro")], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])

        let root = AnyView(
            SearchBar()
                .environment(model)
                .frame(width: 420, height: 40)
                .background(Color.white)
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 420, height: 40)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        // `window.makeFirstResponder(_:)` does not "take" on a window that
        // never became key (measured): `makeKey()` alone, without ordering it
        // onto the screen.
        window.makeKey()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        return Scene(model: model, window: window, hostingView: hostingView)
    }

    private func teardown(_ scene: Scene) {
        scene.window.contentView = nil
        scene.window.orderOut(nil)
        for _ in 0 ..< 5 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Same fix as `InlineLineEditingTests`: `RunLoop.current.run(until:)`
    /// never yields `MainActor` isolation to queued
    /// `DispatchQueue.main.async`/`Task` work; only `try await Task.sleep` (a
    /// REAL `async` function) lets that work run.
    private func pumpAsync(_ seconds: Double = 0.5) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func findSearchField(in view: NSView) -> LelePdfSearchField? {
        if let field = view as? LelePdfSearchField { return field }
        for sub in view.subviews {
            if let found = findSearchField(in: sub) { return found }
        }
        return nil
    }

    @Test("focusSearch() moves the window's REAL first responder to the field (the actual cause of the original bug)")
    func focusSearchMovesRealFirstResponder() async throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        let field = try #require(findSearchField(in: scene.hostingView))

        #expect(scene.window.firstResponder !== field, "the field must not have focus before ⌘F (by default)")
        scene.model.focusSearch()
        await pumpAsync()

        // Real focus always goes to the window's shared FIELD EDITOR when an
        // `NSTextField`/`NSSearchField` becomes first responder, not to the
        // field itself; `NSText.delegate`/`(firstResponder as?
        // NSText)?.delegate` is the correct way to find out WHICH field owns
        // it (Apple's `NSWindow.fieldEditor` docs).
        let responderOwner = (scene.window.firstResponder as? NSText)?.delegate as? NSView
        #expect(responderOwner === field || scene.window.firstResponder === field, "⌘F must move REAL focus to the search field; before the fix it stayed elsewhere")
    }

    @Test("typing in the field updates the query and produces PDF + right-panel results, screenshot of the results")
    func typingUpdatesQueryAndShowsResults() async throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        let field = try #require(findSearchField(in: scene.hostingView))
        scene.model.focusSearch()
        await pumpAsync()

        field.stringValue = "faro"
        // The same event the field editor sends to the delegate when the user
        // types (`NSControl.textDidChangeNotification`).
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        await pumpAsync(1.5) // 150 ms debounce in `DocumentModel.runSearch`

        #expect(scene.model.searchQuery == "faro")
        #expect(scene.model.searchResults.count == 2, "\"faro\" appears twice in the test PDF")
        #expect(scene.model.rewriteSearchBlockIds == ["b1"], "the right-panel card also contains \"faro\"")
        #expect(scene.model.searchTotalCount == 3)

        let outputRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        exportPNG(scene.hostingView, to: outputRoot.appendingPathComponent("f12-search-results.png"))
        #expect(FileManager.default.fileExists(atPath: outputRoot.appendingPathComponent("f12-search-results.png").path))
    }

    /// Directly calls `Coordinator.control(_:textView:doCommandBy:)`, the same
    /// method AppKit invokes during editing of the field, with the same
    /// selector produced by a real ⏎ (`insertNewline:`) or Esc
    /// (`cancelOperation:`). A minimal `NSTextView` acts as a dummy "field
    /// editor": the delegate reads nothing else from it in these two cases.
    private func sendCommand(_ selector: Selector, to field: LelePdfSearchField, coordinator: SearchFieldView.Coordinator) -> Bool {
        let dummyEditor = NSTextView()
        return coordinator.control(field, textView: dummyEditor, doCommandBy: selector)
    }

    @Test("Esc closes the search (closeSearch), the same selector a real Esc produces in the field")
    func escapeInFieldClosesSearch() async throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        let field = try #require(findSearchField(in: scene.hostingView))
        let coordinator = try #require(field.delegate as? SearchFieldView.Coordinator)
        scene.model.focusSearch()
        await pumpAsync()

        scene.model.searchQuery = "faro"
        scene.model.runSearch()
        await pumpAsync(1.5)
        #expect(!scene.model.searchQuery.isEmpty)

        let handled = sendCommand(#selector(NSResponder.cancelOperation(_:)), to: field, coordinator: coordinator)
        #expect(handled, "cancelOperation: must be handled by the delegate (Esc)")

        #expect(scene.model.searchQuery.isEmpty, "Esc must close the search (SPEC §5.10)")
    }

    @Test("⏎ in the field goes to the next result (⇧⏎ → previous remains a live check, see the comment at the top of the file)")
    func returnNavigatesToNextResult() async throws {
        let scene = try makeScene()
        defer { teardown(scene) }
        let field = try #require(findSearchField(in: scene.hostingView))
        let coordinator = try #require(field.delegate as? SearchFieldView.Coordinator)
        scene.model.focusSearch()
        await pumpAsync()

        scene.model.searchQuery = "faro"
        scene.model.runSearch()
        await pumpAsync(1.5)
        #expect(scene.model.currentSearchResultIndex == 0)

        let handled = sendCommand(#selector(NSResponder.insertNewline(_:)), to: field, coordinator: coordinator)
        #expect(handled, "insertNewline: must be handled by the delegate (⏎)")
        #expect(scene.model.currentSearchResultIndex == 1)
    }
}
}
