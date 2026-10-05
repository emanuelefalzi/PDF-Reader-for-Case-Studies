import Foundation
import Testing
@testable import LelePdf

/// Undo/redo of manual marks (SPEC §5.7): controller level, same style as
/// `AnnotationControllerTests`. It calls `performManualMarkUndo`/
/// `performManualMarkRedo` directly (testable without AppKit), plus an
/// integration test with a real `UndoManager` to verify that manual marks and
/// annotations share the same real action order (⌘Z in the Edit menu).
@Suite("AnalysisController · undo/redo of manual marks", .serialized)
@MainActor
struct ManualMarksUndoTests {
    private func block(_ id: String, page: Int = 0, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id, words: 4, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    private func makeController(fingerprint: String, blocks: [TextBlock], analysis: AnalysisRecord = AnalysisRecord()) async -> AnalysisController {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfManualMarksUndoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DocumentStore(dataFolderURL: dir)
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let controller = AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!)
        controller.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: blocks, exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
        return controller
    }

    @Test("adding on a NOT analyzed block: undo removes the created entry ENTIRELY")
    func addOnUnanalyzedBlockUndoRemovesSyntheticEntry() async throws {
        let text = "Il tasso di sconto è salito molto quest'anno."
        let controller = await makeController(fingerprint: "fp1", blocks: [block("b1", text: text)])

        await controller.addManualMark(blockId: "b1", type: .rectangle, text: "tasso di sconto", page: 0, cleanRange: NSRange(location: 3, length: 15))
        #expect(controller.context?.analysis.blocks["b1"] != nil)
        #expect(controller.manualMarksUndoStack.canUndo)

        #expect(controller.performManualMarkUndo())
        #expect(controller.context?.analysis.blocks["b1"] == nil) // no "ghost" entry
        #expect(controller.context?.analysis.terms.isEmpty == true) // the minted term disappears with it

        #expect(controller.performManualMarkRedo())
        let marks = try #require(controller.context?.analysis.blocks["b1"]?.marks)
        #expect(marks.count == 1)
        #expect(marks[0].source == .manual)
        #expect(controller.context?.analysis.terms.count == 1)
    }

    @Test("adding on an ALREADY analyzed block: undo goes back to the previous marks, it does not remove the entry")
    func addOnAnalyzedBlockUndoKeepsEntry() async throws {
        let existingMark = Mark(id: "m1", termId: "t1", type: .rectangle, text: "concetto", source: .claude, page: 0, range: MarkRange(start: 0, length: 8))
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [existingMark])
        let controller = await makeController(fingerprint: "fp2", blocks: [block("b1", text: "concetto importante qui.")], analysis: analysis)

        await controller.addManualMark(blockId: "b1", type: .circle, text: "importante", page: 0, cleanRange: NSRange(location: 9, length: 10))
        #expect(controller.context?.analysis.blocks["b1"]?.marks.count == 2)

        #expect(controller.performManualMarkUndo())
        let reverted = try #require(controller.context?.analysis.blocks["b1"])
        #expect(reverted.status == .analyzed) // the entry stays, it is not removed
        #expect(reverted.marks.map(\.id) == ["m1"])
    }

    @Test("type change: undo goes back to the previous type, redo reapplies it")
    func changeTypeUndoRedo() async throws {
        let existingMark = Mark(id: "m1", termId: "t1", type: .rectangle, text: "concetto", source: .claude, page: 0, range: MarkRange(start: 0, length: 8))
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [existingMark])
        let controller = await makeController(fingerprint: "fp3", blocks: [block("b1", text: "concetto importante qui.")], analysis: analysis)

        await controller.changeMarkType(blockId: "b1", markId: "m1", newType: .circle)
        #expect(controller.context?.analysis.blocks["b1"]?.marks.first?.type == .circle)

        #expect(controller.performManualMarkUndo())
        #expect(controller.context?.analysis.blocks["b1"]?.marks.first?.type == .rectangle)

        #expect(controller.performManualMarkRedo())
        #expect(controller.context?.analysis.blocks["b1"]?.marks.first?.type == .circle)
    }

    @Test("removing a Claude mark: undo unhides it again (hidden goes back to false)")
    func removeClaudeMarkUndoUnhides() async throws {
        let claudeMark = Mark(id: "m1", termId: "t1", type: .rectangle, text: "concetto", source: .claude, page: 0, range: MarkRange(start: 0, length: 8))
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [claudeMark])
        let controller = await makeController(fingerprint: "fp4", blocks: [block("b1", text: "concetto qui.")], analysis: analysis)

        await controller.removeMark(blockId: "b1", markId: "m1")
        #expect(controller.context?.analysis.blocks["b1"]?.marks.first?.hidden == true)

        #expect(controller.performManualMarkUndo())
        #expect(controller.context?.analysis.blocks["b1"]?.marks.first?.hidden == false)
    }

    @Test("removing a manual mark: undo puts it back in the list")
    func removeManualMarkUndoRestores() async throws {
        let manualMark = Mark(id: "m2", termId: "t2", type: .circle, text: "importante", source: .manual, page: 0, range: MarkRange(start: 9, length: 10))
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [manualMark])
        let controller = await makeController(fingerprint: "fp5", blocks: [block("b1", text: "concetto importante qui.")], analysis: analysis)

        await controller.removeMark(blockId: "b1", markId: "m2")
        #expect(controller.context?.analysis.blocks["b1"]?.marks.isEmpty == true)

        #expect(controller.performManualMarkUndo())
        #expect(controller.context?.analysis.blocks["b1"]?.marks.map(\.id) == ["m2"])
    }

    @Test("multiple additions are undone in reverse order (LIFO)")
    func multipleAddsUndoInReverseOrder() async throws {
        let text = "Uno due tre quattro cinque sei sette otto nove dieci."
        let controller = await makeController(fingerprint: "fp6", blocks: [block("b1", text: text)])

        await controller.addManualMark(blockId: "b1", type: .rectangle, text: "Uno", page: 0, cleanRange: NSRange(location: 0, length: 3))
        await controller.addManualMark(blockId: "b1", type: .circle, text: "due", page: 0, cleanRange: NSRange(location: 4, length: 3))
        #expect(controller.context?.analysis.blocks["b1"]?.marks.count == 2)

        #expect(controller.performManualMarkUndo())
        #expect(controller.context?.analysis.blocks["b1"]?.marks.map(\.text) == ["Uno"])

        #expect(controller.performManualMarkUndo())
        #expect(controller.context?.analysis.blocks["b1"] == nil)

        let emptyResult = controller.performManualMarkUndo()
        #expect(!emptyResult) // empty stack, no crash
    }

    @Test("undo/redo on an empty stack does nothing and returns false")
    func emptyStackNoOps() async {
        let controller = await makeController(fingerprint: "fp7", blocks: [block("b1", text: "testo qualsiasi qui.")])
        let undoResult = controller.performManualMarkUndo()
        let redoResult = controller.performManualMarkRedo()
        #expect(!undoResult)
        #expect(!redoResult)
    }

    @Test("updateContext clears the undo/redo stack (new document/relink)")
    func updateContextClearsUndoStack() async throws {
        let text = "Testo di prova per il segno manuale qui."
        let controller = await makeController(fingerprint: "fp8", blocks: [block("b1", text: text)])
        await controller.addManualMark(blockId: "b1", type: .rectangle, text: "Testo", page: 0, cleanRange: NSRange(location: 0, length: 5))
        #expect(controller.manualMarksUndoStack.canUndo)

        controller.updateContext(fingerprint: "fp8", documentTitle: "T", blocks: [block("b1", text: text)], exhibits: [], analysis: controller.context!.analysis, lastAnalyzedBlockId: nil, tocEntries: [])
        #expect(!controller.manualMarksUndoStack.canUndo)
    }

    @Test("updateContext also removes the old actions from the real UndoManager")
    func updateContextClearsSystemUndoActions() async throws {
        let text = "Testo di prova per il segno manuale qui."
        let controller = await makeController(fingerprint: "fp8-system", blocks: [block("b1", text: text)])
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        controller.undoManager = undoManager

        undoManager.beginUndoGrouping()
        await controller.addManualMark(
            blockId: "b1", type: .rectangle, text: "Testo", page: 0,
            cleanRange: NSRange(location: 0, length: 5)
        )
        undoManager.endUndoGrouping()
        #expect(undoManager.canUndo)

        controller.updateContext(
            fingerprint: "fp8-system", documentTitle: "T", blocks: [block("b1", text: text)],
            exhibits: [], analysis: controller.context!.analysis,
            lastAnalyzedBlockId: nil, tocEntries: []
        )
        #expect(!undoManager.canUndo)
        #expect(!controller.manualMarksUndoStack.canUndo)
    }

    @Test("a new analysis invalidates now-stale undo snapshots")
    func analysisSaveClearsManualMarkUndoHistory() async throws {
        let text = "Testo di prova per il segno manuale qui."
        let controller = await makeController(fingerprint: "fp8-analysis", blocks: [block("b1", text: text)])
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        controller.undoManager = undoManager

        undoManager.beginUndoGrouping()
        await controller.addManualMark(
            blockId: "b1", type: .rectangle, text: "Testo", page: 0,
            cleanRange: NSRange(location: 0, length: 5)
        )
        undoManager.endUndoGrouping()
        #expect(undoManager.canUndo)

        controller.queue.onAnalysisSaved?("b1")
        #expect(!undoManager.canUndo)
        #expect(!controller.manualMarksUndoStack.canUndo)
    }

    @Test("rapid undo/redo persist in the same order as the local state")
    func rapidUndoRedoPersistenceKeepsOrder() async throws {
        let text = "Testo di prova per il segno manuale qui."
        let controller = await makeController(fingerprint: "fp8-order", blocks: [block("b1", text: text)])
        await controller.addManualMark(
            blockId: "b1", type: .rectangle, text: "Testo", page: 0,
            cleanRange: NSRange(location: 0, length: 5)
        )

        #expect(controller.performManualMarkUndo())
        #expect(controller.performManualMarkRedo())
        #expect(controller.performManualMarkUndo())
        await controller.waitForPendingManualMarkPersistence()

        #expect(controller.context?.analysis.blocks["b1"] == nil)
        let persisted = await controller.queue.store.currentAnalysis(fingerprint: "fp8-order")
        #expect(persisted?.blocks["b1"] == nil)
        #expect(persisted?.terms.isEmpty == true)
    }

    // MARK: - Integration with the window's real UndoManager

    @Test("⌘Z shared with annotations: the last action of BOTH is undone first")
    func sharedUndoManagerOrdersAcrossControllers() async throws {
        let text = "Testo di prova per il segno manuale qui."
        let controller = await makeController(fingerprint: "fp9", blocks: [block("b1", text: text)])

        let annotationDir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfManualMarksUndoTests-annotations-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: annotationDir, withIntermediateDirectories: true)
        let annotationStore = DocumentStore(dataFolderURL: annotationDir)
        _ = await annotationStore.registerDocument(fingerprint: "fp9-a", byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let annotationController = AnnotationController(store: annotationStore)
        annotationController.load(fingerprint: "fp9-a", items: [])

        // Same `UndoManager` for both controllers, exactly as
        // `MarksOverlayView.viewDidMoveToWindow`/`AnnotationOverlayView.viewDidMoveToWindow`
        // set the same `window.undoManager` on both.
        let undoManager = UndoManager()
        // Without a real `NSApplication` event loop (a test with no running
        // app) `UndoManager`'s automatic per-event grouping has no natural
        // moment to close; Apple's documentation recommends exactly
        // `groupsByEvent = false` plus explicit `beginUndoGrouping`/
        // `endUndoGrouping` in this case.
        undoManager.groupsByEvent = false
        controller.undoManager = undoManager
        annotationController.undoManager = undoManager

        // Explicit `beginUndoGrouping`/`endUndoGrouping` (instead of relying on
        // `UndoManager`'s automatic per-event grouping, which is unreliable in
        // a test without a real `NSApplication` event loop): they
        // deterministically model two distinct user actions, just as in the
        // real app two separate clicks (selection mini bar, then the Annotate
        // bar) each close their own group.
        undoManager.beginUndoGrouping()
        annotationController.createShape(kind: .rectangle, page: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        undoManager.endUndoGrouping()

        undoManager.beginUndoGrouping()
        await controller.addManualMark(blockId: "b1", type: .rectangle, text: "Testo", page: 0, cleanRange: NSRange(location: 0, length: 5))
        undoManager.endUndoGrouping()

        // The last action (the manual mark) must be undone first, not the
        // annotation, even though they belong to two different controllers.
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(controller.context?.analysis.blocks["b1"] == nil)
        #expect(annotationController.annotations.count == 1) // the annotation is untouched

        undoManager.undo()
        #expect(annotationController.annotations.isEmpty)
    }
}
