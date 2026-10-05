import Foundation
import Observation

/// Analysis API for the UI layers, owned by `DocumentModel`. It wraps
/// `AnalysisQueue` (per-block commands/state) and adds the derived views the
/// interface uses: ready-to-show cards, segments in document order, labels. It
/// does not depend on PDFKit: the part that needs it (mark rectangles per
/// page) lives in `AnalysisControllerMarks.swift`.
@MainActor
@Observable
final class AnalysisController {
    let queue: AnalysisQueue

    /// Single source of truth: `AnalysisQueue` already owns `context` and
    /// updates it by itself after every successful analysis
    /// (`applyLocalContextUpdate`), so a second copy in here would go out of
    /// sync every time the queue writes without going through
    /// `updateContext`. The controller simply exposes it by reading the
    /// queue's.
    var context: AnalysisQueue.DocumentContext? { queue.context }

    private(set) var level1TocEntries: [TocEntry] = []
    private(set) var allTocEntries: [TocEntry] = []

    /// Cache of rectangles per page (`AnalysisControllerMarks`), invalidated on
    /// every `updateContext` and every saved analysis. Invalidation after a
    /// single mutation (manual mark added/changed/removed) is targeted at only
    /// the pages of the touched block (`invalidateMarkItems(forPagesOf:)`), no
    /// longer the whole dictionary; `removeAll()` is only used where the
    /// context changes wholesale (`updateContext`) or a real analysis arrives
    /// from the queue (`onAnalysisSaved`, below).
    var markItemsCache: [Int: [PageMarkItem]] = [:]

    /// Cache of repetitions (SPEC §7.5.4), computed once per context instead
    /// of once per VISIBLE PAGE inside `markItems(forPage:)` (the main cause of
    /// slowness when adding/removing a mark with many analyzed blocks). It is
    /// no longer cleared on every mutation: `Repetitions.compute` used to run
    /// on the MainActor (79-511 ms) and now runs on `repetitionsEngine`, off
    /// the MainActor (`AnalysisControllerRepetitions.swift`). This property
    /// stays at the last known value (never `nil`, so as not to block drawing)
    /// until the new result is ready and published by
    /// `applyRepetitions(seq:occurrences:)`.
    var repetitionsCache: [Repetitions.Occurrence]?

    /// Repetitions engine, off the MainActor. The real calls are in
    /// `AnalysisControllerRepetitions.swift`; these three properties stay here
    /// because an extension in another file cannot add instance properties to
    /// a class (the same reason as `markItemsCache`/`repetitionsCache` above).
    let repetitionsEngine = RepetitionsEngine()
    /// Request counter: only the result of the request with the highest `seq`
    /// already applied wins. A safety net on top of the chaining of
    /// `repetitionsTask` below ("an old result can never overwrite a newer
    /// one").
    var repetitionsRequestSeq = 0
    var repetitionsAppliedSeq = 0
    /// Serial chaining (the same pattern as `manualMarksPersistenceTask`
    /// below): each new request waits for the previous one to have FINISHED
    /// publishing its result before starting, so two close requests can never
    /// be applied out of order.
    var repetitionsTask: Task<Void, Never>?

    /// External observer (`DocumentModel`): redraws the PDF overlay when an
    /// analysis is saved. It does not replace `queue.onAnalysisSaved` (which
    /// clears `markItemsCache` above), it is chained to it.
    var onAnalysisSavedExternal: (@MainActor (String) -> Void)?

    /// Separate external observer: the repetition recomputation publishes its
    /// result later, asynchronously. Calling `onAnalysisSavedExternal` again
    /// would also have redone
    /// `mapDataDidChange()`/`scheduleAutomaticPDFSaveIfEnabled()`
    /// (`DocumentModel`) for data that touches neither the map (which computes
    /// its own repetitions, `MapGraphSource`) nor the saved PDF (repetitions
    /// are never written, only real marks; see
    /// `DocumentModelPDFWriting.pdfMarkSnapshots`). Redrawing the overlay is
    /// enough.
    var onRepetitionsUpdated: (@MainActor () -> Void)?

    /// Targeted regenerations in progress, tracked for cancellation (SPEC
    /// §7.6, `AnalysisControllerRegeneration.swift`).
    var regenerationTasks: [String: Task<Void, Never>] = [:]

    /// Blocks with at least one row of the right-hand panel being edited in
    /// place at this moment: a set, not a single `Bool`, because the hand-over
    /// of focus between two rows (the old one's `resignFirstResponder`, the new
    /// one's `onReady`/focus) is not guaranteed to be synchronous within the
    /// same RunLoop turn. Used to disable ⌘↩ ("Analyze the next block",
    /// `AnalysisCommands`) and ⌘F/⌘G/⇧⌘G (search) while a row is being edited
    /// (these shortcuts work from any focus except inside an inline edit).
    var editingLineBlockIds: Set<String> = []
    var isEditingAnyLine: Bool { !editingLineBlockIds.isEmpty }

    func beginEditingLine(blockId: String) { editingLineBlockIds.insert(blockId) }
    func endEditingLine(blockId: String) { editingLineBlockIds.remove(blockId) }

    /// Undo/redo of manual marks (SPEC §5.7): a pure stack, with the bridge to
    /// the window's real `UndoManager` below. The same pattern as
    /// `AnnotationController`/`AnnotationUndoStack`, set by
    /// `MarksOverlayView.viewDidMoveToWindow` on the SAME window `UndoManager`
    /// used by annotations, so ⌘Z/⇧⌘Z interleave the two stacks in the real
    /// order in which actions happened (a single system `UndoManager`, not two
    /// independent ones).
    var manualMarksUndoStack = ManualMarksUndoStack()
    weak var undoManager: UndoManager?
    /// Serial queue of the persistence writes started by synchronous
    /// `UndoManager` handlers. Without an explicit chain, two close
    /// ⌘Z/⇧⌘Z could deliver snapshots to the Store in the opposite order from
    /// the one already correctly applied to the local state.
    var manualMarksPersistenceTask: Task<Void, Never>?

    init(store: DocumentStore, runner: BatchRunner = .shared, defaults: UserDefaults = AppRuntime.defaults) {
        queue = AnalysisQueue(store: store, runner: runner, defaults: defaults)
        queue.onAnalysisSaved = { [weak self] blockId in
            guard let self else { return }
            self.analysisDataDidChange(blockId: blockId, resetManualMarkUndo: true)
        }
    }

    /// Invalidates the derived views after a mutation of the analysis. A real
    /// analysis/regeneration makes the whole `BlockAnalysis` snapshots in the
    /// manual marks stack obsolete, so it also drops the actions registered in
    /// the `UndoManager`; manual mutations call the same path with
    /// `resetManualMarkUndo == false`.
    func analysisDataDidChange(blockId: String, resetManualMarkUndo: Bool) {
        markItemsCache.removeAll()
        // No more `repetitionsCache = nil` here: that recomputation cost
        // 79-511 ms on the MainActor on every mark added/removed and every
        // analysis that arrived. `scheduleRepetitionsIncremental`
        // (`AnalysisControllerRepetitions.swift`) redoes it off the MainActor
        // and publishes the result by itself when it is ready;
        // `repetitionsCache` stays at the last known value in the meantime, so
        // the next `markItems(forPage:)` draws immediately with that instead of
        // waiting (never block drawing).
        scheduleRepetitionsIncremental(changedBlockId: blockId)
        if resetManualMarkUndo { clearManualMarkUndoHistory() }
        onAnalysisSavedExternal?(blockId)
    }

    func clearManualMarkUndoHistory() {
        manualMarksUndoStack.removeAll()
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Used when the window closes, before the Store's `flush`: an undo/redo
    /// updates the UI immediately but must be able to complete its asynchronous
    /// hop to the actor before the final write.
    func waitForPendingManualMarkPersistence() async {
        await manualMarksPersistenceTask?.value
    }

    /// To be called when structure and/or analysis change (open,
    /// re-attachment after resegmentation, generated/updated contents).
    func updateContext(
        fingerprint: String, documentTitle: String, blocks: [TextBlock], exhibits: [ExhibitRef],
        analysis: AnalysisRecord, lastAnalyzedBlockId: String?, tocEntries: [TocEntry],
        summaryGranularity: SummaryGranularity = .heading3
    ) {
        queue.updateContext(AnalysisQueue.DocumentContext(
            fingerprint: fingerprint, documentTitle: documentTitle, blocks: blocks,
            exhibits: exhibits, analysis: analysis, lastAnalyzedBlockId: lastAnalyzedBlockId,
            summaryGranularity: summaryGranularity
        ))
        allTocEntries = tocEntries
        level1TocEntries = tocEntries.filter { $0.level == 1 }
        markItemsCache.removeAll()
        // Structure/analysis changed wholesale, no single block to isolate:
        // everything is recomputed, but off the MainActor
        // (`scheduleRepetitionsFull`); `repetitionsCache` stays what it was
        // until the new one is ready (the same reason as
        // `analysisDataDidChange` above).
        scheduleRepetitionsFull()
        clearManualMarkUndoHistory()
    }

    /// A change to the manual contents (T1-T4 added/changed/renamed/removed)
    /// only changes the entries: "3.2" labels (`humanBlockLabel`), titles
    /// between cards (`documentOrderSegments`), chapter scope. It is not a new
    /// context: no clearing of the mark caches, no recomputation of
    /// repetitions, and above all the manual marks' ⌘Z history is NOT reset as
    /// `updateContext` does (before, "Rename"/"Remove" went through there and
    /// wiped the marks' ⌘Z).
    func updateTocEntries(_ tocEntries: [TocEntry]) {
        allTocEntries = tocEntries
        level1TocEntries = tocEntries.filter { $0.level == 1 }
    }

    // MARK: - Commands (passthrough to AnalysisQueue, SPEC §5.5)

    func analyzeNext() { queue.analyzeNext(fromReadingPosition: nil) }
    func analyzeNext(fromReadingPosition currentBlockId: String?) { queue.analyzeNext(fromReadingPosition: currentBlockId) }
    func analyze(blockId: String) { queue.analyze(blockId: blockId) }
    func cancel(blockId: String) { queue.cancel(blockId: blockId) }
    func retry(blockId: String) { queue.retry(blockId: blockId) }
    func blockState(_ blockId: String) -> BlockQueueState { queue.state(for: blockId) }
    var progress: (analyzed: Int, total: Int) { queue.progress }

    // MARK: - Block card (SPEC §5.6)

    /// `Equatable` not only for tests: `BlockCardView` compares it with
    /// `.equatable()` to skip its own redraw when its block's DATA has not
    /// changed (see there). Before, each card read `context` (the whole
    /// document context, a single `@Observable` property) inside its own
    /// `body`, so replacing the whole `context` on EVERY mark
    /// added/changed/removed invalidated, and re-laid out, all the cards in the
    /// panel, not just the touched block's.
    struct BlockCardData: Sendable, Equatable {
        var title: String
        var rewrite: [ResolvedRewriteItem]
        var page: Int
        /// End page of the block, to show the real range ("p. 4-5") instead of
        /// only the start page when a block crosses several pages (SPEC §7.2).
        var pageEnd: Int
        var edited: Bool
    }

    struct ResolvedRewriteItem: Sendable, Equatable {
        var kind: RewriteKind
        /// For `summary`/`definition`/`callout`/`paragraph`.
        var segments: [ResolvedSegment]?
        /// For `bullets`/`steps`, one list of segments per row.
        var itemSegments: [[ResolvedSegment]]?
        /// Only for `bullets`: `subItemSegments[i]` are the resolved subpoints
        /// of the point `itemSegments[i]` (`nil`/empty if that point has no
        /// subpoints). Parallel to `itemSegments`, not nested inside it:
        /// `RewriteItemView` aligns the two arrays by index.
        var subItemSegments: [[[ResolvedSegment]]]? = nil
        var columns: [String]?
        /// For `table`, a list of rows of cells, each one resolved.
        var rowSegments: [[[ResolvedSegment]]]?
        /// Only for `kind == .outline`: the whole sequence of rows
        /// (point/subpoint/explanation/note/formula/consequence/subheading)
        /// already resolved, `RewriteOutlineReader.lines(for:)` plus
        /// `segments(_:)` row by row. `nil` for every other `kind` (including
        /// `.bullets`, which stays on its own existing rendering via
        /// `itemSegments`/`subItemSegments`, unchanged).
        var lines: [ResolvedLine]? = nil
    }

    /// A row of the rewrite, already resolved: the same shape as
    /// `RewriteLine`, but with `text` replaced by `segments` (`{{mX|...}}`
    /// markers already resolved, as for every other field of
    /// `ResolvedRewriteItem`).
    struct ResolvedLine: Sendable, Equatable {
        var type: RewriteLineType
        var segments: [ResolvedSegment]
    }

    enum ResolvedSegment: Sendable, Equatable {
        case plain(String)
        case marked(text: String, markId: String? = nil, termId: String, type: MarkType)
    }

    func cardData(for blockId: String) -> BlockCardData? {
        PerfProbe.measure("analysis.cardData") { cardDataBody(for: blockId) }
    }

    private func cardDataBody(for blockId: String) -> BlockCardData? {
        guard let context, let blockAnalysis = context.analysis.blocks[blockId], blockAnalysis.status == .analyzed,
              let block = context.blocks.first(where: { $0.id == blockId }) else { return nil }
        let marksById = Dictionary(blockAnalysis.marks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // SPEC §5.7 "Rewrite": a manually marked term that appears in the
        // rewrite is marked there too, case-insensitive. Computed here, at
        // render time, not rewritten into the saved text.
        let manualMarks = blockAnalysis.marks.filter { $0.source == .manual && !$0.hidden }
        return BlockCardData(
            // English fallback, like `orphanCardData`.
            title: blockAnalysis.title ?? "Block",
            rewrite: blockAnalysis.rewrite.map { resolve($0, marksById: marksById, manualMarks: manualMarks) },
            page: block.pageStart,
            pageEnd: block.pageEnd,
            edited: blockAnalysis.rewriteEdited
        )
    }

    /// Raw items (with `{{mX|...}}` markers still inside, without the
    /// render-time highlighting of manual terms) of an analyzed block: used by
    /// `CardEditView` to build the editable text (`RewriteEditText.render`) and
    /// as `originalItems` for `RewriteEditText.parse` on save.
    func rawRewriteItems(for blockId: String) -> [RewriteItem]? {
        context?.analysis.blocks[blockId]?.rewrite
    }

    /// True if the card was edited by hand (SPEC §5.6 "Protection of edits"):
    /// used by the UI to ask for confirmation before regenerating/re-analyzing
    /// an edited card, instead of silently overwriting it.
    func isEdited(blockId: String) -> Bool {
        context?.analysis.blocks[blockId]?.rewriteEdited ?? false
    }

    /// The same shape as `cardData(for:)` but for an ORPHAN analysis (SPEC
    /// §7.3: no longer re-attached to any block of the current segmentation;
    /// old analyses stay readable and exportable until replaced), so without a
    /// real `TextBlock` to take `page`/`pageEnd` from: the caller passes them
    /// from `DocumentModel.orphanBlocks` (`OrphanBlock.page`, the only known
    /// position left). `nil` if the block has no (longer a) saved analysis.
    func orphanCardData(for blockId: String, page: Int) -> BlockCardData? {
        guard let blockAnalysis = context?.analysis.blocks[blockId] else { return nil }
        let marksById = Dictionary(blockAnalysis.marks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let manualMarks = blockAnalysis.marks.filter { $0.source == .manual && !$0.hidden }
        return BlockCardData(
            title: blockAnalysis.title ?? "Block",
            rewrite: blockAnalysis.rewrite.map { resolve($0, marksById: marksById, manualMarks: manualMarks) },
            page: page,
            pageEnd: page,
            edited: blockAnalysis.rewriteEdited
        )
    }

    struct PlaceholderData: Sendable { var page: Int }

    func placeholderData(for blockId: String) -> PlaceholderData? {
        guard let context, let block = context.blocks.first(where: { $0.id == blockId }) else { return nil }
        return PlaceholderData(page: block.pageStart)
    }

    // The resolution of markers now lives in `RewriteResolution`, pure and
    // reused by the Summary Lab (SPEC §5.14) for the "new attempt" column,
    // which has no block already saved in `analisi.json` to start from.
    private func resolve(_ item: RewriteItem, marksById: [String: Mark], manualMarks: [Mark]) -> ResolvedRewriteItem {
        RewriteResolution.resolve(item, marksById: marksById, manualMarks: manualMarks)
    }

    // MARK: - Segments in document order (SPEC §5.6 "in document order")

    enum DocumentSegment: Sendable, Equatable {
        case heading(title: String, level: Int, page: Int)
        case block(blockId: String)
        case exhibit(label: String, page: Int)
    }

    /// Headings, blocks and Exhibits interleaved by page (SPEC §5.6): a
    /// documented approximation, since at this level there is no finer order
    /// than the page. Within the same page, headings come first, then blocks,
    /// then Exhibits.
    ///
    /// This rule alone gets it wrong when a long section is split into several
    /// PARTS (`BlockLabeling`/`TextBlock.partIndex`) and a CONTINUATION part
    /// (not the first) starts on the SAME page where the NEXT section's heading
    /// also starts. That happens when the previous part ends mid-page and the
    /// next section begins lower on the same page (reported as "part 3/3 shown
    /// after the next section's title"). "Headings always before blocks on the
    /// same page" promoted that heading above a continuation that still belongs
    /// to the section ALREADY open: a continuation part (`partIndex` > 1) can
    /// never be overtaken by a heading tied on the same page, so it has a
    /// higher priority than any heading (instead of lower, like a normal
    /// block/the first part of a section, which stay behind their own heading
    /// if on the same page).
    func documentOrderSegments() -> [DocumentSegment] {
        guard let context else { return [] }
        struct Item { let page: Int; let priority: Int; let segment: DocumentSegment }
        var items: [Item] = []
        for entry in allTocEntries {
            items.append(Item(page: entry.page, priority: 0, segment: .heading(title: entry.title, level: entry.level, page: entry.page)))
        }
        for block in context.blocks {
            let isContinuationPart = (block.partIndex ?? 1) > 1
            items.append(Item(page: block.pageStart, priority: isContinuationPart ? -1 : 1, segment: .block(blockId: block.id)))
        }
        for exhibit in context.exhibits {
            items.append(Item(page: exhibit.page, priority: 2, segment: .exhibit(label: exhibit.label, page: exhibit.page)))
        }
        return items.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.page != rhs.element.page { return lhs.element.page < rhs.element.page }
                if lhs.element.priority != rhs.element.priority { return lhs.element.priority < rhs.element.priority }
                return lhs.offset < rhs.offset
            }
            .map(\.element.segment)
    }

    /// Block closest to the current page (SPEC §5.8; usable independently of
    /// the linked scrolling).
    func readingPositionBlock(currentPageIndex: Int) -> String? {
        guard let context else { return nil }
        if let containing = context.blocks.first(where: { $0.pageStart <= currentPageIndex && currentPageIndex <= $0.pageEnd }) {
            return containing.id
        }
        return context.blocks.last(where: { $0.pageStart <= currentPageIndex })?.id ?? context.blocks.first?.id
    }

    /// Exact target in the rewritten text when the mouse is over a repetition
    /// in the PDF (which has no markId of its own). Prefers the term registry's
    /// `firstBlockId`, then falls back to the first visible mark in document
    /// order. It also returns the owning `blockId`: `markId` alone is unique
    /// only within a block (`{{mX|...}}` is a per-block local numbering), never
    /// across the whole document; using it without the block would wrongly
    /// match the "m1" of any block with the "m1" of all the others.
    func firstVisibleMark(for termId: String) -> (blockId: String, markId: String)? {
        guard let context else { return nil }
        if let firstBlockId = context.analysis.terms[termId]?.firstBlockId,
           let mark = context.analysis.blocks[firstBlockId]?.marks.first(where: { $0.termId == termId && !$0.hidden }) {
            return (firstBlockId, mark.id)
        }
        for block in context.blocks {
            if let mark = context.analysis.blocks[block.id]?.marks.first(where: { $0.termId == termId && !$0.hidden }) {
                return (block.id, mark.id)
            }
        }
        return nil
    }

    /// Only the `markId` (several older callers/tests do not need the block):
    /// see `firstVisibleMark(for:)`.
    func firstVisibleMarkId(for termId: String) -> String? {
        firstVisibleMark(for: termId)?.markId
    }

    /// "Continue with the next one". It used to be labeled "Resume from X.Y"
    /// (SPEC §5.5) and was anchored to `progress.lastAnalyzedBlockId`, the LAST
    /// analyzed block in ANY order. When using "Analyze this section"/the card,
    /// or skipping blocks out of order, that id stayed far from where one is
    /// really reading, and the search for the "next non-analyzed" block kept
    /// falling back to the same first block left behind in the document:
    /// effectively "fixed", with no relation to the paragraph on screen
    /// (reported as: the "resume from" button on the right seems stuck on 2.4
    /// rather than relative to the paragraph). The algorithm itself is correct
    /// (`AnalysisQueueTests`); the problem was the anchor. Now the anchor is the
    /// same reading position as the "Analyze the next block" button at the
    /// bottom of the panel (`readingPositionBlock`, SPEC §5.5 "the first
    /// non-analyzed block after the one at the reading position"): the two
    /// buttons stay consistent with each other, and the reference moves with
    /// where one actually reads, not with when the last analysis was clicked.
    func continueLabel(currentPageIndex: Int) -> String? {
        guard let nextId = continueBlockId(currentPageIndex: currentPageIndex) else { return nil }
        return humanBlockLabel(for: nextId)
    }

    /// Id of the block that "Continue with the next one" would analyze.
    func continueBlockId(currentPageIndex: Int) -> String? {
        guard let context else { return nil }
        // `readingPositionBlock` can be `nil` only for an empty document (no
        // blocks): `lastAnalyzedBlockId` remains a reasonable fallback for that
        // edge case, never the normal path.
        let anchor = readingPositionBlock(currentPageIndex: currentPageIndex) ?? context.lastAnalyzedBlockId
        return AnalysisQueue.nextUnanalyzedBlock(blocks: context.blocks, analysis: context.analysis, after: anchor)
    }

    /// "3.2" (algorithm in `BlockLabeling`).
    func humanBlockLabel(for blockId: String) -> String {
        guard let context else { return "0.0" }
        return PerfProbe.measure("analysis.humanLabel") {
            BlockLabeling.humanLabel(blockId: blockId, blocks: context.blocks, level1TocEntries: level1TocEntries)
        }
    }
}
