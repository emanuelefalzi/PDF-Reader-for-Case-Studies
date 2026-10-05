import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// F12 (direct editing and search): live verification of in-place editing of
/// ONE line of a card: a real triple click (`NSEvent`, `clickCount: 3`), a real
/// ⌘↩ that saves, a real Esc that cancels, and focus loss
/// (`window.makeFirstResponder`) that saves as "a click outside" without a
/// global click mechanism. A real `BlockCardView` inside a real
/// `NSWindow`/`NSHostingView`, not an isolated model: the same
/// `MarkedNSTextView`/`EditableMarkedNSTextView` the real app would use.
///
/// The `NSEvent`s are genuine (built with `NSEvent.mouseEvent`/`.keyEvent`,
/// not simulated "by hand" by reading `hitTest`) but sent DIRECTLY to the
/// `override` method that handles them (`mouseDown(with:)`/`keyDown(with:)`)
/// instead of through `NSWindow.sendEvent`: a window ORDERED onto the screen
/// (`makeKeyAndOrderFront`) inside the app-hosted test host proved unstable
/// (very long or stuck runs, measured twice: no crash, no log, the process
/// sat at 0% CPU for minutes), a known risk for this kind of sandboxed
/// environment (no real window server in a test host). The direct call
/// exercises EXACTLY the same code under test (the real override, with the
/// same `NSEvent` object), just without `NSWindow`'s hit-testing round trip,
/// the same trade-off already documented elsewhere in this suite (most of
/// `AnnotationLiveInteractionTests` uses `hitTest`/direct calls, with
/// `NSWindow.sendEvent` reserved for a minimal number of tests).
extension HeavyTestSuites {
@MainActor
@Suite("F12: in-place line editing (triple click, ⌘↩, Esc, click outside)", .serialized)
struct InlineLineEditingTests {
    private func block(_ id: String, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: 0, pageEnd: 0, cleanText: text, textHash: id, words: text.split(separator: " ").count, spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    /// Card with two bullet points (`bullets`): one Claude mark on the first,
    /// one on the second, to check that a line edit touches ONLY the marks of
    /// the edited line, not the whole card.
    private func makeCardModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "alpha first point beta second point", fileName: "inline-edit-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "inline-edit-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        var analysis = AnalysisRecord()
        analysis.terms["t1"] = TermRecord(term: "alpha", type: .rectangle, firstBlockId: "b1")
        analysis.terms["t2"] = TermRecord(term: "beta", type: .rectangle, firstBlockId: "b1")
        let rewrite = [RewriteItem(kind: .bullets, items: ["{{m1|alpha}} first point", "{{m2|beta}} second point"])]
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Prova", rewrite: rewrite, claudeRewrite: rewrite,
            marks: [
                Mark(id: "m1", termId: "t1", type: .rectangle, text: "alpha", source: .claude, page: 0, range: MarkRange(start: 0, length: 5)),
                Mark(id: "m2", termId: "t2", type: .rectangle, text: "beta", source: .claude, page: 0, range: MarkRange(start: 19, length: 4)),
            ]
        )
        model.analysisController.updateContext(fingerprint: "fp-inline-edit-\(UUID().uuidString)", documentTitle: "Prova", blocks: [block("b1", text: "alpha first point beta second point")], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
        return model
    }

    /// Only the card's lines, with in-place editing active, WITHOUT the rest of
    /// `BlockCardView` (title, page chip, "…" menu, regeneration `.alert`/
    /// `.sheet`): same pattern as `CardItemOverlapTests.CardItemsProbe` (which
    /// reuses `RewriteItemView` on its own for a DIFFERENT problem).
    /// `RewriteEditableLine`/`MarkedNSTextView`/`EditableMarkedNSTextView`/
    /// `AnalysisController.saveManualEditLine` are exactly the same code
    /// `BlockCardView` would use; the `.onChange` below reproduces
    /// `BlockCardView.commitLineEdit`/`editingLine` by hand, the only part that
    /// is "reimplemented" rather than reused directly.
    private struct EditableCardProbe: View {
        let items: [AnalysisController.ResolvedRewriteItem]
        let model: DocumentModel
        let blockId: String
        @State var editingLine: RewriteLineEditingTarget?

        var body: some View {
            CardContainer {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    RewriteItemView(
                        item: item, itemIndex: index, model: model, blockId: blockId, isEditable: true,
                        editingLine: $editingLine,
                        onCommitLine: { ref, text, spans in
                            Task { await model.analysisController.saveManualEditLine(blockId: blockId, ref: ref, editedText: text, editedSpans: spans) }
                            editingLine = nil
                        }
                    )
                }
            }
            .padding(14)
            .background(Color.white)
            .onChange(of: editingLine) { _, newValue in
                if newValue != nil {
                    model.analysisController.beginEditingLine(blockId: blockId)
                } else {
                    model.analysisController.endEditingLine(blockId: blockId)
                }
            }
        }
    }

    private struct Scene {
        let model: DocumentModel
        let window: NSWindow
        let hostingView: NSHostingView<AnyView>
    }

    private func makeScene(_ model: DocumentModel) throws -> Scene {
        let items = try #require(model.analysisController.cardData(for: "b1")?.rewrite)
        let root = AnyView(
            EditableCardProbe(items: items, model: model, blockId: "b1")
                .environment(model)
                .frame(width: 360)
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        // `window.makeFirstResponder(_:)` (used by `InlineLineEditView.
        // makeNSView`) does not "stick" on a window that never became key;
        // measured in this session: `firstResponder` stayed the window itself
        // despite a generous RunLoop margin. `makeKey()` alone (WITHOUT
        // `orderFront`/`makeKeyAndOrderFront`, the part that is genuinely
        // unstable in this host) fixes it without reintroducing that risk:
        // no real compositing/window on screen, only the internal "key" state
        // that focus requires.
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

    /// Measured in this session: `RunLoop.current.run(until:)` is NOT enough to
    /// wait for the scheduled focus (`InlineLineEditView.makeNSView`,
    /// `DispatchQueue.main.async`) or for the save's
    /// `Task { await saveManualEditLine(...) }`: a synchronous `RunLoop` turn
    /// never yields `MainActor` isolation (where both run), so they stayed
    /// queued forever while the test itself kept it busy.
    /// `try await Task.sleep(...)`, which genuinely SUSPENDS the test (an
    /// `async` function), hands the `MainActor` to the real Swift Concurrency
    /// scheduler and lets that work run; the only fix that made the suite
    /// green in this session, verified with a real run (not deduced).
    private func pumpAsync(_ seconds: Double = 0.5) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func findMarkedTextView(containing text: String, in view: NSView) -> MarkedNSTextView? {
        if let tv = view as? MarkedNSTextView, tv.string.contains(text) { return tv }
        for sub in view.subviews {
            if let found = findMarkedTextView(containing: text, in: sub) { return found }
        }
        return nil
    }

    private func findEditableTextView(in view: NSView) -> EditableMarkedNSTextView? {
        if let tv = view as? EditableMarkedNSTextView { return tv }
        for sub in view.subviews {
            if let found = findEditableTextView(in: sub) { return found }
        }
        return nil
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    /// Real triple click on the center of the line found: a genuine `NSEvent`
    /// (`clickCount: 3`) sent DIRECTLY to `mouseDown(with:)` (see the comment
    /// at the top of the file on why not `NSWindow.sendEvent` here).
    private func tripleClick(on textView: MarkedNSTextView, in window: NSWindow) {
        let midPoint = NSPoint(x: textView.bounds.midX, y: textView.bounds.midY)
        let windowPoint = textView.convert(midPoint, to: nil)
        textView.mouseDown(with: mouseEvent(.leftMouseDown, at: windowPoint, in: window, clickCount: 3))
    }

    @Test("triple click on the SECOND line makes it editable, ⌘↩ saves ONLY that line (the other line's marks untouched)")
    func tripleClickEditsSecondLineAndCommandReturnSavesOnlyThatLine() async throws {
        let model = try makeCardModel()
        let scene = try makeScene(model)
        defer { teardown(scene) }

        let textView = try #require(findMarkedTextView(containing: "second point", in: scene.hostingView), "MarkedNSTextView of the second line not found in the real hierarchy")
        tripleClick(on: textView, in: scene.window)
        await pumpAsync()

        let editor = try #require(findEditableTextView(in: scene.hostingView), "the triple click should have opened the line editor")
        #expect(editor.string == "beta second point")
        #expect(model.analysisController.isEditingAnyLine, "AnalysisController must know that a line is being edited")
        #expect(scene.window.firstResponder === editor, "the editor must become first responder so typing can start right away")

        // Screenshot of the line in edit mode (brief: "Export PNGs of a line in edit mode").
        let outputRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        exportPNG(scene.hostingView, to: outputRoot.appendingPathComponent("f12-inline-edit-line-active.png"))
        #expect(FileManager.default.fileExists(atPath: outputRoot.appendingPathComponent("f12-inline-edit-line-active.png").path))

        // Type at the end of the text (real NSTextView; `insertText` is the
        // same path AppKit would use for real typing; arrows, selection,
        // ⌘A/⌘C/⌘V/⌘X/⌘Z are default `NSTextView` behavior, untouched by this
        // work, so not repeated character by character here).
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" EDITED", replacementRange: editor.selectedRange())
        #expect(editor.string == "beta second point EDITED")

        // Real ⌘↩: must save ONLY this line.
        editor.keyDown(with: keyEvent("\r", modifiers: .command, in: scene.window))
        await pumpAsync()

        #expect(!model.analysisController.isEditingAnyLine, "editing must close after ⌘↩")
        let saved = try #require(model.analysisController.context?.analysis.blocks["b1"])
        #expect(saved.rewrite.first?.items?[1] == "{{m2|beta}} second point EDITED")
        // The first line (with {{m1|alpha}}) must not be touched.
        #expect(saved.rewrite.first?.items?[0] == "{{m1|alpha}} first point")
        #expect(saved.marks.first(where: { $0.id == "m1" })?.hidden == false)
        #expect(saved.marks.first(where: { $0.id == "m2" })?.hidden == false) // "beta" is still in the saved text
        #expect(saved.rewriteEdited == true)
    }

    @Test("Esc cancels: the text goes back to the saved one, nothing is saved")
    func escapeCancelsWithoutSaving() async throws {
        let model = try makeCardModel()
        let scene = try makeScene(model)
        defer { teardown(scene) }

        let textView = try #require(findMarkedTextView(containing: "first point", in: scene.hostingView))
        tripleClick(on: textView, in: scene.window)
        await pumpAsync()

        let editor = try #require(findEditableTextView(in: scene.hostingView))
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("testo scartato", replacementRange: editor.selectedRange())

        editor.keyDown(with: keyEvent("\u{1b}", modifiers: [], in: scene.window))
        await pumpAsync()

        #expect(!model.analysisController.isEditingAnyLine)
        let saved = try #require(model.analysisController.context?.analysis.blocks["b1"])
        #expect(saved.rewrite.first?.items?[0] == "{{m1|alpha}} first point") // unchanged
        #expect(saved.rewriteEdited == false)
        #expect(findEditableTextView(in: scene.hostingView) == nil, "the editor must disappear after Esc")
    }

    @Test("a click outside (focus loss) saves, without a \"Save\" button")
    func clickingOutsideSaves() async throws {
        let model = try makeCardModel()
        let scene = try makeScene(model)
        defer { teardown(scene) }

        let textView = try #require(findMarkedTextView(containing: "first point", in: scene.hostingView))
        tripleClick(on: textView, in: scene.window)
        await pumpAsync()

        let editor = try #require(findEditableTextView(in: scene.hostingView))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" MORE", replacementRange: editor.selectedRange())

        // "A click outside": move focus elsewhere in the SAME window (here, to
        // the window itself); `resignFirstResponder` fires on its own, no real
        // gesture/click on another control is needed to prove the save logic.
        scene.window.makeFirstResponder(nil)
        await pumpAsync()

        #expect(!model.analysisController.isEditingAnyLine, "the click outside must close editing")
        let saved = try #require(model.analysisController.context?.analysis.blocks["b1"])
        #expect(saved.rewrite.first?.items?[0] == "{{m1|alpha}} first point MORE")
    }

    @Test("⌘↩ while a line is being edited does not start \"Analyze the next block\" (controller-level flag)")
    func commandReturnDuringEditingDoesNotTriggerAnalysis() async throws {
        let model = try makeCardModel()
        let scene = try makeScene(model)
        defer { teardown(scene) }

        let textView = try #require(findMarkedTextView(containing: "first point", in: scene.hostingView))
        tripleClick(on: textView, in: scene.window)
        await pumpAsync()
        let editor = try #require(findEditableTextView(in: scene.hostingView))
        #expect(model.analysisController.isEditingAnyLine)

        // Same principle the codebase already chose for "controller-level flag,
        // UI alert tested via view model": the real command (`AnalysisCommands`,
        // `App/DocumentCommands.swift`) reads EXACTLY this flag in its own
        // `.disabled`. The proof that matters is that the flag is true while
        // editing is open (the real menu cannot be built in a test host without
        // a real `NSApplication`/`DocumentGroup` scene; see `RealMenuBarTests`
        // for verification of the REAL menu on a genuinely open document).
        #expect(model.isSearchAvailable == false, "⌘F must be disabled in the same way while a line is being edited")

        // ⌘↩ in the test window (no real `AnalysisCommands` wired up here): the
        // line itself intercepts it and saves. Checking that NOTHING ELSE
        // listens to the same event is out of scope for this test; it is
        // verified instead by reading `isEditingAnyLine` above and the line's
        // save below (behavior identical to
        // `tripleClickEditsSecondLineAndCommandReturnSavesOnlyThatLine`).
        editor.keyDown(with: keyEvent("\r", modifiers: .command, in: scene.window))
        await pumpAsync()
        #expect(!model.analysisController.isEditingAnyLine)
    }
}
}
