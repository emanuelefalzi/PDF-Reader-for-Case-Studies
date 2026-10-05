import Foundation
import Testing
@testable import LelePdf

/// Manual marks, text editing and protection of edits (SPEC §5.6,
/// §5.7): real integration with `AnalysisController`/`DocumentStore`
/// (temporary folder), no Claude calls — those are already covered by
/// `AnalysisControllerTests.regenerateReplacesClaudeMarksKeepsManual`.
@Suite("AnalysisController · manual marks and text editing")
struct AnalysisControllerManualMarksTests {
    private func tempStore() throws -> (store: DocumentStore, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfManualMarksTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DocumentStore(dataFolderURL: dir), { try? FileManager.default.removeItem(at: dir) })
    }

    private func block(_ id: String, page: Int = 0, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id, words: 4, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    @MainActor
    private func makeController(store: DocumentStore) -> AnalysisController {
        AnalysisController(store: store, runner: BatchRunner(timeout: 5), defaults: UserDefaults(suiteName: "lelepdf-test-\(UUID())")!)
    }

    // MARK: - Add/change/remove (SPEC §5.7)

    @Test("addManualMark on a block NOT yet analyzed: allowed, state stays idle")
    func manualMarkOnUnanalyzedBlock() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp1"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let text = "Il tasso di sconto è salito molto quest'anno."
        let b1 = block("b1", text: text)

        let controller = await MainActor.run { () -> AnalysisController in
            let c = makeController(store: store)
            c.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [b1], exhibits: [], analysis: AnalysisRecord(), lastAnalyzedBlockId: nil, tocEntries: [])
            return c
        }

        await controller.addManualMark(blockId: "b1", type: .rectangle, text: "tasso di sconto", page: 0, cleanRange: NSRange(location: 3, length: 15))

        let state = await MainActor.run { controller.blockState("b1") }
        #expect(state == .idle) // SPEC "make sure placeholders/progress aren't confused"
        let saved = await MainActor.run { controller.context?.analysis.blocks["b1"] }
        let marks = try #require(saved?.marks)
        #expect(marks.count == 1)
        #expect(marks[0].source == .manual)
        #expect(marks[0].type == .rectangle)
    }

    @Test("changeMarkType: updates the type, keeps the original source")
    func changeMarkType() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp2"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let existingMark = Mark(id: "m1", termId: "t1", type: .rectangle, text: "concetto", source: .claude, page: 0, range: MarkRange(start: 0, length: 8))
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [existingMark])
        let b1 = block("b1", text: "concetto importante qui.")

        let controller = await MainActor.run { () -> AnalysisController in
            let c = makeController(store: store)
            c.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [b1], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
            return c
        }
        await controller.changeMarkType(blockId: "b1", markId: "m1", newType: .circle)

        let updated = await MainActor.run { controller.context?.analysis.blocks["b1"]?.marks.first }
        #expect(updated?.type == .circle)
        #expect(updated?.source == .claude) // the source does not change
    }

    @Test("removeMark: a Claude mark is hidden, a manual one is deleted")
    func removeMarkHidesClaudeDeletesManual() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp3"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let claudeMark = Mark(id: "m1", termId: "t1", type: .rectangle, text: "concetto", source: .claude, page: 0, range: MarkRange(start: 0, length: 8))
        let manualMark = Mark(id: "m2", termId: "t2", type: .circle, text: "importante", source: .manual, page: 0, range: MarkRange(start: 9, length: 10))
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, marks: [claudeMark, manualMark])
        let b1 = block("b1", text: "concetto importante qui.")

        let controller = await MainActor.run { () -> AnalysisController in
            let c = makeController(store: store)
            c.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [b1], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
            return c
        }
        await controller.removeMark(blockId: "b1", markId: "m1")
        await controller.removeMark(blockId: "b1", markId: "m2")

        let marks = await MainActor.run { controller.context?.analysis.blocks["b1"]?.marks ?? [] }
        #expect(marks.count == 1)
        #expect(marks[0].id == "m1")
        #expect(marks[0].hidden == true)
        #expect(!marks.contains { $0.id == "m2" }) // manual one really deleted
    }

    // MARK: - Text editing (SPEC §5.6)

    @Test("saveManualEdit: updates the text, sets 'rewriteEdited', keeps claudeRewrite")
    func saveManualEditSetsFlag() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp4"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let claudeRewrite = [RewriteItem(kind: .paragraph, text: "Testo originale di Claude.")]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, rewrite: claudeRewrite, rewriteEdited: false, claudeRewrite: claudeRewrite)
        let b1 = block("b1", text: "Testo di prova.")

        let controller = await MainActor.run { () -> AnalysisController in
            let c = makeController(store: store)
            c.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [b1], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
            return c
        }
        await controller.saveManualEdit(blockId: "b1", editedText: "Testo modificato a mano.", editedSpans: [])

        let updated = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        #expect(updated.rewriteEdited == true)
        #expect(updated.rewrite.first?.text == "Testo modificato a mano.")
        #expect(updated.claudeRewrite == claudeRewrite) // Claude's version intact
        let isEdited = await MainActor.run { controller.isEdited(blockId: "b1") }
        #expect(isEdited)
        #expect(RewriteViewModel.needsOverwriteConfirmation(edited: isEdited))
    }

    @Test("saveManualEdit: a mark whose text disappears entirely is hidden (Claude) or deleted (manual)")
    func saveManualEditPrunesVanishedMarks() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp5"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let claudeMark = Mark(id: "m1", termId: "t1", type: .rectangle, text: "tasso", source: .claude, page: 0, range: MarkRange(start: 3, length: 5))
        let manualMark = Mark(id: "m2", termId: "t2", type: .circle, text: "sconto", source: .manual, page: 0, range: MarkRange(start: 9, length: 6))
        let rewrite = [RewriteItem(kind: .paragraph, text: "Il {{m1|tasso}} di {{m2|sconto}} è salito.")]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, rewrite: rewrite, claudeRewrite: rewrite, marks: [claudeMark, manualMark])
        let b1 = block("b1", text: "Il tasso di sconto è salito.")

        let controller = await MainActor.run { () -> AnalysisController in
            let c = makeController(store: store)
            c.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [b1], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
            return c
        }
        // The user deletes both marked terms, no span survives.
        await controller.saveManualEdit(blockId: "b1", editedText: "Il  di  è salito.", editedSpans: [])

        let updated = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        let claude = try #require(updated.marks.first { $0.id == "m1" })
        #expect(claude.hidden == true)
        #expect(!updated.marks.contains { $0.id == "m2" })
    }

    @Test("restoreClaudeVersion: goes back to claudeRewrite, clears 'rewriteEdited'")
    func restoreClaudeVersion() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp6"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let claudeRewrite = [RewriteItem(kind: .paragraph, text: "Versione di Claude.")]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, rewrite: [RewriteItem(kind: .paragraph, text: "Versione modificata.")], rewriteEdited: true, claudeRewrite: claudeRewrite)
        let b1 = block("b1", text: "Testo di prova.")

        let controller = await MainActor.run { () -> AnalysisController in
            let c = makeController(store: store)
            c.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [b1], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
            return c
        }
        await controller.restoreClaudeVersion(blockId: "b1")

        let updated = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        #expect(updated.rewriteEdited == false)
        #expect(updated.rewrite == claudeRewrite)
    }

    @Test("restoreClaudeVersion: also rebuilds the Claude marks removed/changed during editing")
    func restoreClaudeVersionRebuildsMarks() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp7"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let claudeMark1 = Mark(id: "m1", termId: "t1", type: .rectangle, text: "tasso", source: .claude, page: 0, range: MarkRange(start: 3, length: 5))
        let claudeMark2 = Mark(id: "m2", termId: "t2", type: .circle, text: "sconto", source: .claude, page: 0, range: MarkRange(start: 9, length: 6))
        let manualMark = Mark(id: "m3", termId: "t3", type: .underline, text: "salito", source: .manual, page: 0, range: MarkRange(start: 22, length: 6))
        let claudeLink = Link(id: "l1", from: "t1", to: "t2", label: "influenza", kind: .effect, source: .claude)
        let claudeRewrite = [RewriteItem(kind: .paragraph, text: "Il {{m1|tasso}} di {{m2|sconto}} è {{m3|salito}}.")]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, rewrite: claudeRewrite, claudeRewrite: claudeRewrite,
            marks: [claudeMark1, claudeMark2, manualMark], links: [claudeLink],
            claudeMarks: [claudeMark1, claudeMark2], claudeLinks: [claudeLink]
        )
        let b1 = block("b1", text: "Il tasso di sconto è salito.")

        let controller = await MainActor.run { () -> AnalysisController in
            let c = makeController(store: store)
            c.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [b1], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
            return c
        }

        // The user changes the type of a Claude mark...
        await controller.changeMarkType(blockId: "b1", markId: "m1", newType: .arrow)
        // ...then edits the text, removing the reference to Claude's second mark (m2).
        let editedItems = [RewriteItem(kind: .paragraph, text: "Il {{m1|tasso}} di sconto è {{m3|salito}}.")]
        let built = RewriteEditText.render(items: editedItems)
        await controller.saveManualEdit(blockId: "b1", editedText: built.text, editedSpans: built.spans)

        let beforeRestore = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        #expect(beforeRestore.rewriteEdited == true)
        #expect(beforeRestore.marks.first { $0.id == "m1" }?.type == .arrow)
        #expect(beforeRestore.marks.first { $0.id == "m2" }?.hidden == true)

        await controller.restoreClaudeVersion(blockId: "b1")

        let restored = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        #expect(restored.rewriteEdited == false)
        #expect(restored.rewrite == claudeRewrite)
        // Claude's marks come back EXACTLY as Claude produced them.
        #expect(restored.marks.first { $0.id == "m1" } == claudeMark1)
        #expect(restored.marks.first { $0.id == "m2" } == claudeMark2)
        // The manual mark is not touched by the restore.
        #expect(restored.marks.first { $0.id == "m3" } == manualMark)
        #expect(restored.marks.count == 3)
        // Claude's link comes back too.
        #expect(restored.links.contains(claudeLink))
    }

    @Test("restoreClaudeVersion: an analysis saved BEFORE this fix (claudeMarks nil) leaves the marks untouched")
    func restoreClaudeVersionWithoutSnapshotLeavesMarksUntouched() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp8"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let hiddenClaudeMark = Mark(id: "m1", termId: "t1", type: .rectangle, text: "tasso", source: .claude, page: 0, range: MarkRange(start: 3, length: 5), hidden: true)
        let claudeRewrite = [RewriteItem(kind: .paragraph, text: "Versione di Claude.")]
        var analysis = AnalysisRecord()
        // claudeMarks/claudeLinks not set: `nil`, like a file written before the Claude snapshot existed.
        analysis.blocks["b1"] = BlockAnalysis(
            status: .analyzed, rewrite: [RewriteItem(kind: .paragraph, text: "Versione modificata.")],
            rewriteEdited: true, claudeRewrite: claudeRewrite, marks: [hiddenClaudeMark]
        )
        let b1 = block("b1", text: "Il tasso di sconto è salito.")

        let controller = await MainActor.run { () -> AnalysisController in
            let c = makeController(store: store)
            c.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [b1], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
            return c
        }
        await controller.restoreClaudeVersion(blockId: "b1")

        let updated = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        #expect(updated.rewrite == claudeRewrite)
        #expect(updated.marks == [hiddenClaudeMark]) // unchanged, no snapshot available
    }

    // MARK: - Protection of edits (SPEC §5.6)

    @Test("needsOverwriteConfirmation: false on an unedited card")
    func noConfirmationWhenNotEdited() {
        #expect(RewriteViewModel.needsOverwriteConfirmation(edited: false) == false)
    }

    // MARK: - Per-line editing (F12)

    @Test("saveManualEditLine: touches ONLY the given line, a mark in another line stays intact")
    func saveManualEditLineIsScopedToOneLine() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp-line1"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let claudeMarkLine0 = Mark(id: "m1", termId: "t1", type: .rectangle, text: "alpha", source: .claude, page: 0, range: MarkRange(start: 0, length: 5))
        let claudeMarkLine1 = Mark(id: "m2", termId: "t2", type: .circle, text: "beta", source: .claude, page: 0, range: MarkRange(start: 6, length: 4))
        let rewrite = [RewriteItem(kind: .bullets, items: ["{{m1|alpha}} first", "{{m2|beta}} second"])]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, rewrite: rewrite, claudeRewrite: rewrite, marks: [claudeMarkLine0, claudeMarkLine1])
        let b1 = block("b1", text: "alpha first beta second")

        let controller = await MainActor.run { () -> AnalysisController in
            let c = makeController(store: store)
            c.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [b1], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
            return c
        }
        // The user edits ONLY line 0 and deletes "alpha" (that line's mark
        // disappears). No span survives because the edited line no longer
        // contains any — but the "beta" mark sits in ANOTHER line, never touched
        // by this save: it must stay visible, unlike a save on the whole card,
        // where the "originally editable" set would include both.
        await controller.saveManualEditLine(blockId: "b1", ref: .bulletMain(itemIndex: 0, index: 0), editedText: "first only", editedSpans: [])

        let updated = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        #expect(updated.rewrite.first?.items?[0] == "first only")
        #expect(updated.rewrite.first?.items?[1] == "{{m2|beta}} second") // line 1 intact
        let m1 = try #require(updated.marks.first { $0.id == "m1" })
        #expect(m1.hidden == true) // gone from line 0: hidden (Claude)
        let m2 = try #require(updated.marks.first { $0.id == "m2" })
        #expect(m2.hidden == false) // was never in the edited line: intact
        #expect(updated.rewriteEdited == true)
    }

    @Test("saveManualEditLine: a manual mark that survives in the edited line stays, one deleted entirely disappears")
    func saveManualEditLineHandlesManualMarks() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp-line2"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let manualMark = Mark(id: "m1", termId: "t1", type: .circle, text: "gamma", source: .manual, page: 0, range: MarkRange(start: 0, length: 5))
        let rewrite = [RewriteItem(kind: .paragraph, text: "{{m1|gamma}} resta identico.")]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, rewrite: rewrite, claudeRewrite: rewrite, marks: [manualMark])
        let b1 = block("b1", text: "gamma resta identico.")
        let controller = await MainActor.run { () -> AnalysisController in
            let c = makeController(store: store)
            c.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [b1], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
            return c
        }
        // The surrounding text changes, the marked term stays: the span survives.
        await controller.saveManualEditLine(
            blockId: "b1", ref: .whole(itemIndex: 0), editedText: "gamma resta ancora identico.",
            editedSpans: [RewriteEditText.MarkSpan(range: NSRange(location: 0, length: 5), markId: "m1")]
        )
        let updated = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        #expect(updated.rewrite.first?.text == "{{m1|gamma}} resta ancora identico.")
        #expect(updated.marks.contains { $0.id == "m1" }) // manual, survived: intact

        // Now the same manual mark disappears from the line entirely: really deleted (not just hidden).
        await controller.saveManualEditLine(blockId: "b1", ref: .whole(itemIndex: 0), editedText: "testo senza il termine.", editedSpans: [])
        let updated2 = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        #expect(!updated2.marks.contains { $0.id == "m1" })
    }

    @Test("saveManualEditLine: panel-level ⌘Z undoes the line edit (same stack/UndoManager as manual marks)")
    func saveManualEditLineSupportsUndo() async throws {
        let (store, cleanup) = try tempStore()
        defer { cleanup() }
        let fingerprint = "fp-line3"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 1)
        let rewrite = [RewriteItem(kind: .paragraph, text: "Testo originale.")]
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(status: .analyzed, rewrite: rewrite, claudeRewrite: rewrite)
        let b1 = block("b1", text: "Testo originale.")
        let controller = await MainActor.run { () -> AnalysisController in
            let c = makeController(store: store)
            c.updateContext(fingerprint: fingerprint, documentTitle: "T", blocks: [b1], exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: [])
            return c
        }
        await controller.saveManualEditLine(blockId: "b1", ref: .whole(itemIndex: 0), editedText: "Testo cambiato.", editedSpans: [])
        let afterEdit = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        #expect(afterEdit.rewrite.first?.text == "Testo cambiato.")

        let undone = await MainActor.run { controller.performManualMarkUndo() }
        #expect(undone)
        let afterUndo = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        #expect(afterUndo.rewrite.first?.text == "Testo originale.")
        #expect(afterUndo.rewriteEdited == false)

        let redone = await MainActor.run { controller.performManualMarkRedo() }
        #expect(redone)
        let afterRedo = try #require(await MainActor.run { controller.context?.analysis.blocks["b1"] })
        #expect(afterRedo.rewrite.first?.text == "Testo cambiato.")
    }
}
