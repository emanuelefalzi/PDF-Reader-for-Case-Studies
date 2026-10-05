import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// F17 area 2: review of the summary panel. Each test corresponds to one fix
/// and failed before it (verified with a real run, not inferred).
extension HeavyTestSuites {
@MainActor
@Suite("F17 area 2 · summary panel: reconfigurations, context, real editing, strings", .serialized)
struct RewritePanelReviewF17Tests {
    private func block(_ id: String, page: Int, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id, words: text.split(separator: " ").count, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    private static let firstText = "alpha first point beta second point"
    private static let secondText = "gamma third point delta fourth point"

    /// Two analyzed cards (`bullets` with two points, one Claude mark on the
    /// first line of each), no contents.
    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: Self.firstText + " " + Self.secondText, fileName: "review-f17a2-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "review-f17a2")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
        var analysis = AnalysisRecord()
        analysis.terms["t1"] = TermRecord(term: "alpha", type: .rectangle, firstBlockId: "b1")
        analysis.terms["t2"] = TermRecord(term: "gamma", type: .rectangle, firstBlockId: "b2")
        let rewrite1 = [RewriteItem(kind: .bullets, items: ["{{m1|alpha}} first point", "beta second point"])]
        let rewrite2 = [RewriteItem(kind: .bullets, items: ["{{m1|gamma}} third point", "delta fourth point"])]
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "First", rewrite: rewrite1, claudeRewrite: rewrite1,
            marks: [Mark(id: "m1", termId: "t1", type: .rectangle, text: "alpha", source: .claude, page: 0, range: MarkRange(start: 0, length: 5))]
        )
        analysis.blocks["b2"] = BlockAnalysis(
            status: .analyzed, title: "Second", rewrite: rewrite2, claudeRewrite: rewrite2,
            marks: [Mark(id: "m1", termId: "t2", type: .rectangle, text: "gamma", source: .claude, page: 0, range: MarkRange(start: 0, length: 5))]
        )
        updateContext(model, analysis: analysis, blocks: [block("b1", page: 0, text: Self.firstText), block("b2", page: 0, text: Self.secondText)])
        return model
    }

    private func updateContext(_ model: DocumentModel, analysis: AnalysisRecord, blocks: [TextBlock]) {
        model.analysisController.updateContext(fingerprint: "fp-review-f17a2", documentTitle: "Prova", blocks: blocks, exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
    }

    private struct Scene {
        let window: NSWindow
        let hostingView: NSHostingView<AnyView>
    }

    /// The REAL panel (`RewritePanel` in `RewriteScrollHost`, lazy stack) in a
    /// real window, like `RewritePanelLazyRealizationTests`.
    private func makeScene(_ model: DocumentModel) -> Scene {
        let viewport = CGSize(width: DSMetrics.rightPanelDefaultWidth, height: 600)
        let hostingView = NSHostingView(rootView: AnyView(RewritePanel().environment(model).frame(width: viewport.width, height: viewport.height)))
        hostingView.frame = CGRect(origin: .zero, size: viewport)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        return Scene(window: window, hostingView: hostingView)
    }

    private func pump(_ hostingView: NSView, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            hostingView.layoutSubtreeIfNeeded()
        }
    }

    /// See `InlineLineEditingTests.pumpAsync`: only a real suspension yields
    /// the MainActor to the save `Task`s and to the scheduled focus.
    private func pumpAsync(_ seconds: Double = 0.5) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func textViews(in view: NSView) -> [MarkedNSTextView] {
        var result: [MarkedNSTextView] = []
        if let text = view as? MarkedNSTextView { result.append(text) }
        for subview in view.subviews { result += textViews(in: subview) }
        return result
    }

    private func findEditableTextView(in view: NSView) -> EditableMarkedNSTextView? {
        if let tv = view as? EditableMarkedNSTextView { return tv }
        for sub in view.subviews {
            if let found = findEditableTextView(in: sub) { return found }
        }
        return nil
    }

    /// If the line does NOT accept triple-click (`onTripleClick == nil`, as in
    /// the real card from F12 to F17), `MarkedNSTextView.mouseDown` falls back
    /// to `super.mouseDown`, which in `NSTextView` is a mouse-tracking loop
    /// waiting for a mouse-up that never arrives in a test (process stuck at
    /// 0% CPU, sampled in this session): here we fail immediately instead of
    /// hanging.
    private func tripleClick(on textView: MarkedNSTextView, in window: NSWindow) throws {
        try #require(textView.onTripleClick != nil, "the real card's line must accept triple-click (`isEditable: true` in BlockCardView)")
        let midPoint = NSPoint(x: textView.bounds.midX, y: textView.bounds.midY)
        let windowPoint = textView.convert(midPoint, to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 3, pressure: 1)!
        textView.mouseDown(with: event)
    }

    // MARK: - configure with unchanged inputs redoes nothing

    @Test("configure with the same text/marks/font neither rebuilds the text nor empties the height cache")
    func configureIsIdempotentForIdenticalInputs() {
        let view = MarkedNSTextView()
        let built = MarkedTextBuilder.build([.marked(text: "alpha", markId: "m1", termId: "t1", type: .rectangle), .plain(" first point of a line long enough to wrap twice at least")])
        let color = NSColor(DSColor.textPrimary)
        view.configure(text: built.text, marks: built.marks, fontSize: 12.5, textColor: color, lineSpacing: 4)
        #expect(view.appliedConfigurationCount == 1)
        _ = view.measuredSize(forWidth: 120)

        PerfProbe.isEnabled = true
        defer { PerfProbe.isEnabled = false; PerfProbe.reset() }
        PerfProbe.reset()
        view.configure(text: built.text, marks: built.marks, fontSize: 12.5, textColor: color, lineSpacing: 4, searchHighlightRanges: [NSRange(location: 0, length: 5)])
        #expect(view.appliedConfigurationCount == 1, "same inputs: no new configuration")
        _ = view.measuredSize(forWidth: 120)
        let snapshot = PerfProbe.snapshot()
        #expect((snapshot["text.measure.cached"]?.count ?? 0) == 1, "the height measured earlier must still be cached")
        #expect((snapshot["text.measure"]?.count ?? 0) == 0)
        #expect((snapshot["text.configure.unchanged"]?.count ?? 0) == 1)

        // A genuinely different input reconfigures as before.
        view.configure(text: built.text + "!", marks: built.marks, fontSize: 12.5, textColor: color, lineSpacing: 4)
        #expect(view.appliedConfigurationCount == 2)
        view.configure(text: built.text + "!", marks: built.marks, fontSize: 12.5, textColor: color, lineSpacing: 4, italic: true)
        #expect(view.appliedConfigurationCount == 3, "italic is part of the signature")
    }

    // MARK: - a context mutation re-evaluates only the touched card

    @Test("a manual mark on block 2 neither re-evaluates card 1's body nor reconfigures the lines that stayed the same")
    func contextMutationRevaluatesOnlyTheTouchedCard() async throws {
        let model = try makeModel()
        let scene = makeScene(model)
        defer { closeTestWindow(scene.window) }
        pump(scene.hostingView, seconds: 0.6)
        #expect(textViews(in: scene.hostingView).count == 4, "two cards with two lines each")

        PerfProbe.isEnabled = true
        defer { PerfProbe.isEnabled = false; PerfProbe.reset() }
        PerfProbe.reset()
        let word = "delta"
        let start = Self.secondText.distance(from: Self.secondText.startIndex, to: Self.secondText.range(of: word)!.lowerBound)
        await model.analysisController.addManualMark(blockId: "b2", type: .underline, text: word, page: 0, cleanRange: NSRange(location: start, length: word.count))
        pump(scene.hostingView, seconds: 0.4)
        await pumpAsync(0.2)
        let snapshot = PerfProbe.snapshot()
        #expect((snapshot["swiftui.BlockCardView.body"]?.count ?? 0) == 1, "only block 2's card: \(snapshot["swiftui.BlockCardView.body"]?.count ?? 0) bodies")
        #expect((snapshot["text.configure"]?.count ?? 0) == 1, "only the line containing the new mark: \(snapshot["text.configure"]?.count ?? 0) reconfigurations")
        let manual = model.analysisController.context?.analysis.blocks["b2"]?.marks.last(where: { $0.source == .manual })
        #expect(manual != nil)
    }

    // MARK: - the real card is truly editable

    @Test("every line of the real card accepts triple-click and opens it for editing (editing was switched off in the real card)")
    func realCardLinesAreEditable() async throws {
        let model = try makeModel()
        let scene = makeScene(model)
        defer { closeTestWindow(scene.window) }
        pump(scene.hostingView, seconds: 0.6)
        let lines = textViews(in: scene.hostingView)
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0.onTripleClick != nil }, "`RewriteItemView.isEditable` is `false` by default: the real card must pass `true`")
        #expect(!model.analysisController.isEditingAnyLine)

        let line = try #require(lines.first { $0.string.contains("second point") })
        try tripleClick(on: line, in: scene.window)
        pump(scene.hostingView, seconds: 0.3)
        #expect(findEditableTextView(in: scene.hostingView) != nil, "triple-click must replace the line with the editor")
        #expect(model.analysisController.isEditingAnyLine)
        #expect(model.rewritePanelGeometry.pinned.contains("b-b1"))

        // Esc: the editor closes without saving and the bookkeeping is freed
        // again; before the fix `editingLine` stayed set forever (no editor
        // could reset it to `nil`), leaving ⌘↩/⌘F disabled.
        let editor = try #require(findEditableTextView(in: scene.hostingView))
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: scene.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        editor.keyDown(with: esc)
        pump(scene.hostingView, seconds: 0.3)
        await pumpAsync(0.2)
        #expect(findEditableTextView(in: scene.hostingView) == nil)
        #expect(!model.analysisController.isEditingAnyLine)
        #expect(!model.rewritePanelGeometry.pinned.contains("b-b1"))
        #expect(model.analysisController.context?.analysis.blocks["b1"]?.rewrite.first?.items?[1] == "beta second point", "Esc does not save")
    }

    // MARK: - card disappeared while a line is being edited

    @Test("if the block being edited leaves the segmentation, the editing flag and the pin are released")
    func editingFlagReleasedWhenCardDisappears() async throws {
        let model = try makeModel()
        let scene = makeScene(model)
        defer { closeTestWindow(scene.window) }
        pump(scene.hostingView, seconds: 0.6)

        let line = try #require(textViews(in: scene.hostingView).first { $0.string.contains("first point") })
        try tripleClick(on: line, in: scene.window)
        pump(scene.hostingView, seconds: 0.3)
        #expect(model.analysisController.isEditingAnyLine)
        #expect(model.rewritePanelGeometry.pinned.contains("b-b1"))
        #expect(findEditableTextView(in: scene.hostingView) != nil)

        // New segmentation without block 1 (granularity change): its card
        // disappears from the panel.
        let analysis = try #require(model.analysisController.context?.analysis)
        updateContext(model, analysis: analysis, blocks: [block("b2", page: 0, text: Self.secondText)])
        pump(scene.hostingView, seconds: 0.5)
        await pumpAsync(0.3)

        #expect(findEditableTextView(in: scene.hostingView) == nil, "the editor disappeared with the card")
        #expect(!model.analysisController.isEditingAnyLine, "without the release, ⌘↩ and ⌘F would stay disabled forever")
        #expect(!model.rewritePanelGeometry.pinned.contains("b-b1"))
    }

    @Test("if the whole panel is torn down while a line is being edited, the editing flag is released")
    func editingFlagReleasedWhenPanelIsDismantled() async throws {
        let model = try makeModel()
        let scene = makeScene(model)
        pump(scene.hostingView, seconds: 0.6)
        let line = try #require(textViews(in: scene.hostingView).first { $0.string.contains("first point") })
        try tripleClick(on: line, in: scene.window)
        pump(scene.hostingView, seconds: 0.3)
        #expect(model.analysisController.isEditingAnyLine)

        closeTestWindow(scene.window)
        pump(scene.hostingView, seconds: 0.3)
        await pumpAsync(0.3)
        #expect(!model.analysisController.isEditingAnyLine)
        #expect(model.rewritePanelGeometry.pinned.isEmpty)
    }

    // MARK: - English fallback string

    @Test("an untitled card shows \"Block\", not \"Blocco\"")
    func untitledCardFallsBackToEnglish() throws {
        let model = try makeModel()
        var analysis = try #require(model.analysisController.context?.analysis)
        analysis.blocks["b1"]?.title = nil
        updateContext(model, analysis: analysis, blocks: [block("b1", page: 0, text: Self.firstText)])
        #expect(model.analysisController.cardData(for: "b1")?.title == "Block")
        #expect(model.analysisController.orphanCardData(for: "b1", page: 0)?.title == "Block")
    }

    // MARK: - Exploratory: ⌘Z after a line edit

    @Test("after ⌘↩ the first ⌘Z undoes the line edit in the panel")
    func undoAfterInlineEditRestoresTheLine() async throws {
        let model = try makeModel()
        let scene = makeScene(model)
        defer { closeTestWindow(scene.window) }
        scene.window.makeKey()
        pump(scene.hostingView, seconds: 0.6)
        let undoManager = try #require(scene.window.undoManager)
        model.analysisController.undoManager = undoManager

        let line = try #require(textViews(in: scene.hostingView).first { $0.string.contains("second point") })
        try tripleClick(on: line, in: scene.window)
        await pumpAsync(0.5)
        let editor = try #require(findEditableTextView(in: scene.hostingView))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" EDITED", replacementRange: editor.selectedRange())
        let typingUndoRegisteredInWindowManager = undoManager.canUndo
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: scene.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 0)!
        editor.keyDown(with: event)
        await pumpAsync(0.5)
        #expect(model.analysisController.context?.analysis.blocks["b1"]?.rewrite.first?.items?[1] == "beta second point EDITED")

        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == "edit text", "the panel's edit must be on top of the stack, not the typing of the now-closed editor")
        undoManager.undo()
        await pumpAsync(0.5)
        #expect(model.analysisController.context?.analysis.blocks["b1"]?.rewrite.first?.items?[1] == "beta second point")
        // After undoing the edit, no typing group from the closed editor must
        // remain (a no-op ⌘Z for the user).
        #expect(!undoManager.canUndo || undoManager.undoActionName != "Typing", "dead typing groups: registered in the window's manager=\(typingUndoRegisteredInWindowManager), canUndo=\(undoManager.canUndo), name=\(undoManager.undoActionName)")
    }
}
}
