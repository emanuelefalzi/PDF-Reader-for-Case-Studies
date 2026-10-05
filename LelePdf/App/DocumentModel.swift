import AppKit
import Foundation
import Observation
@preconcurrency import PDFKit

/// Left sidebar tabs (SPEC §5.3). Verbatim feedback from the user after
/// trying the previous version: "I liked the left menu better before, now
/// with this split, one piece on top and one below, I really don't like
/// it, put it back as it was": three entries in a row, **Pages / Contents /
/// Map**, as before the split, no longer the contents always present above
/// a two-entry segmented control.
enum SidebarTab: String, CaseIterable, Sendable {
    case pagine, indice, mappa

    var label: String {
        switch self {
        case .pagine: String(localized: "Pages")
        case .indice: String(localized: "Contents")
        case .mappa: String(localized: "Map")
        }
    }
}

/// Search scope (SPEC §5.10).
enum SearchScope: String, CaseIterable, Sendable {
    case capitolo, tuttoIlPDF
}

/// Analysis state of a page for the dot in the Pages sidebar
/// (SPEC §5.3).
enum PageAnalysisStatus: Sendable, Equatable {
    case none, partial, full

    /// Pure (no dependency on `DocumentModel`/PDFKit), so it is testable on
    /// its own (M5b deliverable 7 "dots full/half").
    static func compute(analyzedCount: Int, totalTouching: Int) -> PageAnalysisStatus {
        guard totalTouching > 0, analyzedCount > 0 else { return .none }
        return analyzedCount == totalTouching ? .full : .partial
    }
}

enum PDFSaveState: Equatable {
    case idle
    case saving
    case saved(String)
    case failed(String)
}

/// Central state of a document window (SPEC §6.2 "App", §6.3: one
/// `@Observable` `DocumentModel` on the MainActor per window). Later
/// milestones extend it: marks and rewrite (M5), linked scrolling (M6),
/// edits (M7), map (M8), chat (M9).
@MainActor
@Observable
final class DocumentModel {
    // MARK: - Document

    let pdfDocument: PDFDocument
    let displayName: String
    let sourceData: Data
    /// Path of the file on disk (SPEC §8 `lastKnownPath`), from
    /// `FileDocumentConfiguration.fileURL`. `nil` for the in-memory documents
    /// used by previews/tests: in that case the Store does not come into play
    /// (no file from which to compute the fast hash).
    let fileURL: URL?
    /// Snapshot of the default when the window opens: it applies only if the
    /// PDF turns out to be new. Changing Settings does not recolor documents
    /// already open or earlier records (SPEC: default "for new documents").
    private let initialColorTheme: MaterialHue
    /// Like `initialColorTheme` above, but for the summary granularity; it
    /// applies only if the document turns out to be new
    /// (`DocumentStore.registerDocument`). An already existing document never
    /// receives this value: it stays `nil` (the previous behavior) until the
    /// user explicitly chooses. Not `private`: also read by
    /// `DocumentModelSummaryGranularity.swift`.
    let initialSummaryGranularity: SummaryGranularity

    var pageCount: Int { pdfDocument.pageCount }

    // MARK: - Store (SPEC §8, M3)

    /// True fingerprint of the document, known only after the fast path
    /// (hash of the bytes) or after the pipeline has computed it from the text.
    private(set) var storeFingerprint: String?
    /// Published for the UI (placeholder until M5/M7 for marks and
    /// rewrite): SPEC M3 point 4 "model.documentRecord, model.analysis".
    var documentRecord: DocumentRecord?
    var analysis: AnalysisRecord?
    /// SPEC §8 "Downloading from iCloud...": true while the Store waits for
    /// a not-yet-downloaded data file to arrive from iCloud.
    var iCloudDownloading = false
    /// Saved analyses that did not re-attach to a block of the current
    /// segmentation (SPEC §7.3): shown at their old page, the interface
    /// arrives in M5.
    var orphanBlocks: [OrphanBlock] = []

    private var cachedByteHash: String?
    /// Page touched before the fingerprint was known (fast path still in
    /// progress): applied to the Store as soon as it is available.
    private var pendingLastReadPage: Int?
    /// Subject color chosen from the legend BEFORE the fingerprint is known
    /// (fast path still in progress, like `pendingLastReadPage` above):
    /// applied to the Store as soon as it is available.
    private var pendingColorTheme: MaterialHue?
    /// Like `pendingColorTheme` above, for an entry collapsed/expanded BEFORE
    /// the fingerprint is known (fast path still in progress): applied to
    /// the Store as soon as it is available (`applyStoreResult`). Not
    /// `private`: read/written also by `DocumentModelTocCollapse.swift` (same
    /// type, separate file to keep files short).
    var pendingCollapsedTocEntryIds: Set<String>?

    // MARK: - Navigation

    var currentPageIndex: Int
    var visiblePageRange: ClosedRange<Int> = 0...0
    var zoomPercent: Int = 100
    /// Position (page space) at the top of the currently visible part of the
    /// PDF, updated on every scroll (`ScrollSyncCoordinator`, not only on
    /// page changes): the Chapters sidebar uses it to highlight the entry
    /// closest to the real reading position, not just to the page. `nil` until
    /// the PDF has been laid out for the first time.
    var currentReadingPageY: Double?

    // MARK: - Contents (SPEC §5.3, §7.4)

    var tocEntries: [TocEntry] = []
    var tocSource: TocSource = .none
    /// State of the contents generation (SPEC §7.4, §5.3, M4): drives the
    /// empty/loading/error state of the Chapters sidebar.
    var tocGenerationState: TocGenerationState = .idle
    /// Bug "the heading above gets highlighted": the entry just clicked in
    /// `goToTocEntry`, kept as the "real" entry for the Chapters sidebar until
    /// the user really scrolls again (`ScrollSyncCoordinator.handleScrolled`
    /// clears it). See `currentTocEntry` (`DocumentModelTocNavigation.swift`).
    var pinnedTocEntryID: String?
    /// Pure undo/redo stack for the manual contents (adding/changing the
    /// T1-T4 level, from both the selection bar button and ⌘⌥1…4), the same
    /// pattern as `AnalysisController.manualMarksUndoStack`/
    /// `ManualMarksUndo.swift`, with a bridge to the system `UndoManager` in
    /// `DocumentModelManualTocUndo.swift`.
    var manualTocUndoStack = ManualTocUndoStack()
    /// Selection pieces accumulated while holding ⌘
    /// (`MarksOverlayMultiSelection.swift`): each element is an already
    /// "closed" `PDFSelection` (the drag gesture that created it has ended).
    /// Emptied by a click without ⌘, by Esc, or consumed by ⌘⌥1…4 after
    /// creating the entries.
    var multiSelectionPieces: [PDFSelection] = []

    // MARK: - Text pipeline (SPEC §7, M2)

    /// Result published by `PipelineRunner` when ready. `nil` until
    /// `pipelineState` is `.ready` (or if the document has no pages).
    var structure: DocumentStructure?
    var pipelineState: PipelineState = .idle
    /// Debug › "Show Blocks" menu (SPEC §11 row M2): draws the overlay of
    /// block boundaries above the PDF (see `Reader/DebugOverlay.swift`).
    var debugShowBlocks = false {
        didSet { readerBridge?.updateDebugAnnotations(structure: structure, show: debugShowBlocks) }
    }

    // MARK: - Thumbnails (SPEC §5.3)

    /// Created immediately, not lazily: see the comment on `ThumbnailCache.init`.
    let thumbnailCache: ThumbnailCache

    // MARK: - Interface state (SPEC §5.1)

    /// Sidebar visibility (SPEC §5.1), now also remembered per app
    /// (⌘⌥1 ... "with the state remembered"), the same principle as
    /// `sidebarWidth`/`sidebarTab` below: `PaneWidthStore` (key
    /// `sidebarVisible`), not document data.
    var sidebarVisible: Bool = true {
        didSet {
            guard sidebarVisible != oldValue else { return }
            PaneWidthStore.setSidebarVisible(sidebarVisible)
        }
    }
    /// Selected tab: three entries in a row, Pages/Contents/Map (restoring
    /// the earlier shape). Remembered per app in `UserDefaults`
    /// (`SidebarPreferences`), not in the document, the same principle as
    /// `PaneWidthStore`: it applies to all windows opened later, not only to
    /// the one that changed tab. It takes the place of `indexVisible`
    /// (removed: there is no longer a contents panel to show/hide with a
    /// dedicated button, the tab choice itself acts as show/hide and is what
    /// is "remembered").
    var sidebarTab: SidebarTab = .pagine {
        didSet {
            guard sidebarTab != oldValue else { return }
            SidebarPreferences.setSidebarTab(sidebarTab)
        }
    }
    /// Collapsible legend: visible through hover of the left edge (local
    /// state of the `Sidebar` view) OR forced from here through the
    /// "Legend" shortcut/menu entry (⌥⌘G, `DocumentCommands`). Never
    /// persisted: it is session state, not a preference like `sidebarTab`.
    var legendForcedVisible: Bool = false
    /// Draggable width of the sidebar (SPEC §5.1: 200-360 pt). The initial
    /// value is remembered in `UserDefaults` (`PaneWidthStore`, key
    /// `sidebarWidth`) per window: here it starts from the app default,
    /// `init` overwrites it with the last saved one before wiring the
    /// `didSet`.
    var sidebarWidth: CGFloat = DSMetrics.sidebarWidth {
        didSet {
            guard sidebarWidth != oldValue else { return }
            PaneWidthStore.setSidebarWidth(sidebarWidth)
        }
    }
    /// Right panel visibility (SPEC §5.1), remembered like `sidebarVisible`
    /// above (key `rightPanelVisible`).
    var rightPanelVisible: Bool = true {
        didSet {
            guard rightPanelVisible != oldValue else { return }
            PaneWidthStore.setRightPanelVisible(rightPanelVisible)
        }
    }
    /// Draggable width of the right panel (SPEC §5.1: 320-520 pt),
    /// remembered like `sidebarWidth` above (key `rightPanelWidth`).
    var rightPanelWidth: CGFloat = DSMetrics.rightPanelDefaultWidth {
        didSet {
            guard rightPanelWidth != oldValue else { return }
            PaneWidthStore.setRightPanelWidth(rightPanelWidth)
        }
    }
    var followPDF: Bool = true

    // MARK: - Map (SPEC §5.3, §7.7)

    var mapScope: MapScope = .chapter
    var mapExpanded = false
    var mapZoom = 1.0
    /// Changes when the Store, structure or analysis modify the map data.
    /// Views use it as the id of the debounced task, without comparing the
    /// full text of the blocks on the MainActor.
    private(set) var mapDataRevision = 0

    // MARK: - Search (SPEC §5.10)

    var searchQuery: String = ""
    var searchScope: SearchScope = .capitolo
    var searchResults: [PDFSelection] = []
    /// Blocks of the right panel whose resolved text contains `searchQuery`
    /// (document order), LISTED AFTER the PDF results (`searchResults` above)
    /// in the combined space that `currentSearchResultIndex`/`searchNext`/
    /// `searchPrevious` walk through; SPEC §5.10 extended to "also in the
    /// summary ... after the PDF results".
    var rewriteSearchBlockIds: [String] = []
    var currentSearchResultIndex: Int?
    /// Incremented by the ⌘F command to ask the search field
    /// (`SearchFieldView`) to take REAL focus (`window.
    /// makeFirstResponder`, no longer just `@FocusState`: `@FocusState` alone
    /// did not move real focus for a field hosted in a `ToolbarItem`).
    var searchFocusToken: Int = 0
    private var searchTask: Task<Void, Never>?

    /// Combined total PDF + right panel, for "n of N".
    var searchTotalCount: Int { searchResults.count + rewriteSearchBlockIds.count }

    // MARK: - Analysis (SPEC §5.5, §7.5, M5a/M5b)

    /// Content of the titlebar pill (SPEC §5.1 point 7, §5.5): `nil` =
    /// hidden (no block analyzed yet and no analysis running); otherwise
    /// static progress "12 of 58 blocks" or, during an analysis, "Analysis
    /// 3.2 · 12 of 58 blocks" with a spinner.
    struct AnalysisPillInfo: Equatable {
        var isRunning: Bool
        var runningLabel: String?
        var analyzed: Int
        var total: Int
    }

    var analysisPillInfo: AnalysisPillInfo? {
        let (analyzed, total) = analysisController.progress
        guard total > 0 else { return nil }
        if let runningId = analysisController.queue.runningBlockId {
            return AnalysisPillInfo(isRunning: true, runningLabel: analysisController.humanBlockLabel(for: runningId), analyzed: analyzed, total: total)
        }
        guard analyzed > 0 else { return nil }
        return AnalysisPillInfo(isRunning: false, runningLabel: nil, analyzed: analyzed, total: total)
    }

    /// Analysis API for M5b/M6/M7/M8 (SPEC M5a deliverable 6): queue, cards,
    /// segments in document order, targeted regeneration.
    let analysisController: AnalysisController

    // MARK: - Free annotations, Preview style (SPEC §5.13, M7b)

    /// One instance per window, like `analysisController`/`syncCoordinator`:
    /// annotation state, active tool, undo/redo. Native rendering
    /// (`AnnotationRenderer`) and mouse interaction (`AnnotationOverlayView`)
    /// stay in the Reader (PDFKit, MainActor).
    let annotationController = AnnotationController()
    /// Native annotations read from the file before removing from the
    /// in-memory copy only those signed by LelePdf.
    let annotationsReadFromPDF: PDFAnnotationImporter.Result
    var pdfSaveState: PDFSaveState = .idle
    var automaticPDFSaveTask: Task<Void, Never>?

    /// The window's ephemeral conversation (SPEC §5.9, §6.3).
    let chatController: ChatController

    // MARK: - Linked hover (SPEC §5.8, basis for M6): the PDF side and the
    // right panel (both AppKit views inside an `NSViewRepresentable`, not
    // pure SwiftUI) do not redraw by themselves when an `@Observable`
    // property changes; `setHover` also publishes a notification
    // (`Notification.Name.lelePdfHoverChanged`) that `MarksOverlayView` and
    // `MarkedTextView` observe to invalidate their own drawing.
    private(set) var hoveredTermId: String?
    private(set) var hoveredMarkId: String?
    /// Block owning `hoveredMarkId` (reported by the user: "many more get
    /// highlighted"): `markId` alone is a block-local numbering (`{{mX|...}}`
    /// restarts at m1 in every analyzed block), never unique across the whole
    /// document; `HoverLinking.state` requires that BOTH match before
    /// lighting up a mark as the "exact counterpart" of the hover.
    private(set) var hoveredMarkBlockId: String?

    /// - Parameters:
    ///   - blockId: block owning the exact `markId` (`nil` for the "broad"
    ///     hover from a map node, SPEC §5.3, or when there is no precise
    ///     target).
    func setHover(termId: String?, markId: String? = nil, blockId: String? = nil) {
        guard termId != hoveredTermId || markId != hoveredMarkId || blockId != hoveredMarkBlockId else { return }
        PerfProbe.hit("model.setHover")
        hoveredTermId = termId
        hoveredMarkId = markId
        hoveredMarkBlockId = blockId
        NotificationCenter.default.post(name: .lelePdfHoverChanged, object: self)
    }

    // MARK: - "Focused" block (SPEC §5.6/§5.8; "it's not clear which card
    // belongs to which section"): distinct from the hover over MARKS above.
    // Here no markId is needed, only "which block the mouse is in", to
    // accent the matching card in the right panel and strengthen the margin
    // bar in the PDF (in both directions).

    private(set) var hoveredBlockId: String?

    func setHoveredBlock(_ blockId: String?) {
        guard blockId != hoveredBlockId else { return }
        PerfProbe.hit("model.setHoveredBlock")
        hoveredBlockId = blockId
        NotificationCenter.default.post(name: .lelePdfHoverChanged, object: self)
    }

    /// Block to accent right now: the one under the mouse if any (PDF or
    /// card), otherwise the one at the current reading position, so the accent
    /// never disappears entirely, it only changes source.
    var currentFocusedBlockId: String? {
        hoveredBlockId ?? analysisController.readingPositionBlock(currentPageIndex: currentPageIndex)
    }

    // MARK: - Link to the PDFKit view

    /// Set by `PDFKitView` when the `NSView` is created. Commands to the PDF
    /// always go through here (see `PDFReaderBridge`).
    var readerBridge: PDFReaderBridge?

    // MARK: - Linked scrolling (SPEC §5.8, M6)

    /// One instance per window, like `analysisController`: observes the two
    /// `NSScrollView`s (PDF and right panel) and makes one follow the other
    /// (see `Sync/ScrollSyncCoordinator.swift`).
    let syncCoordinator = ScrollSyncCoordinator()
    /// Set by `RewriteScrollHost` when the right panel's `NSScrollView` is
    /// created (weak: the view stays owned by AppKit).
    weak var rewriteScrollView: NSScrollView?
    /// Geometry of the lazy right panel: heights of all rows (measured or
    /// estimated), built window, rectangles for `syncCoordinator`. One
    /// instance per window.
    let rewritePanelGeometry = RewritePanelGeometry()

    /// Bug "full screen takes 3 seconds": one instance per window, like
    /// `syncCoordinator`; see `Sync/WindowResizeCoalescer.swift` for the cause
    /// and the fix. Connected to the real `NSWindow` by
    /// `MarksOverlayView.viewDidMoveToWindow`.
    let windowResizeCoalescer = WindowResizeCoalescer()

    // MARK: - Initialization

    init?(document: PDFFileDocument, fileURL: URL? = nil) {
        guard let pdfDocument = PDFDocument(data: document.data) else { return nil }
        let annotationsReadFromPDF = PDFAnnotationImporter.readAndDetachOwned(from: pdfDocument)
        self.pdfDocument = pdfDocument
        self.annotationsReadFromPDF = annotationsReadFromPDF
        self.displayName = document.displayName
        self.sourceData = document.data
        self.fileURL = fileURL
        self.initialColorTheme = DefaultColorThemePreference.read(defaults: AppRuntime.defaults)
        self.initialSummaryGranularity = DefaultSummaryGranularityPreference.read(defaults: AppRuntime.defaults)
        self.thumbnailCache = ThumbnailCache(document: pdfDocument)
        self.analysisController = AnalysisController(store: AppStore.shared)
        self.chatController = ChatController()
        self.syncCoordinator.measurement = SyncMeasurement.makeIfEnabled(label: document.displayName)

        // New windows start from the last dragged width (app default in
        // `UserDefaults`, not document data).
        if let savedSidebarWidth = PaneWidthStore.sidebarWidth() { self.sidebarWidth = savedSidebarWidth }
        if let savedRightPanelWidth = PaneWidthStore.rightPanelWidth() { self.rightPanelWidth = savedRightPanelWidth }
        // The sidebar tab (Pages/Contents/Map) is remembered per app, not per
        // document; read here like the widths above.
        self.sidebarTab = SidebarPreferences.sidebarTab()
        // As above, for the sidebar/right panel visibility (state remembered).
        self.sidebarVisible = PaneWidthStore.sidebarVisible()
        self.rightPanelVisible = PaneWidthStore.rightPanelVisible()

        let restoredPage = LastPageStore.lastPage(for: document.data)
        if let restoredPage, restoredPage >= 0, restoredPage < pdfDocument.pageCount {
            self.currentPageIndex = restoredPage
        } else {
            self.currentPageIndex = 0
        }

        let rawOutline = NativeOutline.extractRaw(from: pdfDocument)
        if OutlineEvaluator.isUseful(entries: rawOutline, pageCount: pdfDocument.pageCount) {
            self.tocEntries = NativeOutline.extractEntries(from: pdfDocument)
            self.tocSource = .native
        } else {
            self.tocEntries = []
            self.tocSource = .none
        }

        self.analysisController.onAnalysisSavedExternal = { [weak self] _ in
            guard let self else { return }
            self.analysis = self.analysisController.context?.analysis
            self.mapDataDidChange()
            self.readerBridge?.invalidateOverlay()
            self.scheduleAutomaticPDFSaveIfEnabled()
        }
        // Recomputing the repetitions publishes its own result later, off the
        // MainActor: redrawing the marks overlay is enough, there is no need to
        // also redo `mapDataDidChange()` (the map computes its own repetitions
        // by itself, `MapGraphSource`) nor schedule an automatic PDF save
        // (repetitions never end up there, only real marks).
        self.analysisController.onRepetitionsUpdated = { [weak self] in
            self?.readerBridge?.invalidateOverlay()
        }
        self.annotationController.onMutationCommitted = { [weak self] in
            self?.scheduleAutomaticPDFSaveIfEnabled()
        }
        beginStoreFastLookup()
        beginMeasurementAutorunIfNeeded()
    }

    // MARK: - Linked scrolling: measurement (SPEC §5.8, M6)

    /// Also called by the Debug menu "Measure Scrolling"
    /// (`DebugCommands.swift`), besides the automatic start below.
    func runMeasurementSequence() async {
        await SyncMeasurementRunner.run(model: self)
    }

    /// `LELEPDF_MEASURE_AUTORUN=1` (used only by `scripts/measure-sync.sh`,
    /// never by a normal interactive launch): starts the measurement run by
    /// itself, without needing the Debug menu; SPEC §5.8 deliverable 4
    /// "fallback", see `SyncMeasurementRunner`.
    private func beginMeasurementAutorunIfNeeded() {
        guard ProcessInfo.processInfo.environment["LELEPDF_MEASURE_AUTORUN"] == "1" else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.runMeasurementSequence()
            // Hard rule: "the autorun must quit the app by itself when it has
            // finished". It was missing (`scripts/measure-sync.sh` relied only on
            // external `osascript quit`/`pkill`, with a real race between closing
            // one instance and opening the next: `open` of the Draghi report arrived
            // while macOS still considered the instance of the Merck case that had
            // just terminated as "running", failing with "was already running").
            // Only here, not in `runMeasurementSequence()` itself: that one is
            // shared with the manual Debug menu action "Measure Scrolling" in a
            // real interactive session, which must never quit the app.
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Store: fast path (SPEC §5.2, §8, M3 point 4)

    private func beginStoreFastLookup() {
        guard let fileURL else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.performFastLookup(fileURL: fileURL)
        }
    }

    private func performFastLookup(fileURL: URL) async {
        if let status = try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
           status != .current {
            iCloudDownloading = true
        }
        let result = await AppStore.shared.fastLookup(fileURL: fileURL)
        iCloudDownloading = false
        cachedByteHash = result.byteHash
        guard let fingerprint = result.fingerprint, let record = result.record else { return }
        applyStoreResult(fingerprint: fingerprint, record: record, analysis: result.analysis ?? AnalysisRecord(), annotations: result.annotations ?? AnnotationsRecord())
    }

    /// Called by `PipelineRunner` when the structure is ready (SPEC §7, M3
    /// point 4): registers/updates the document in the Store (creates the
    /// folder the first time, or reconciles rename/move), saves
    /// contents/blocks/Exhibits and republishes `documentRecord`/`analysis`.
    /// It does not block the MainActor: the hash was already computed by the
    /// fast path (`cachedByteHash`), only `Sendable` values are passed here.
    func attachStructureToStore(_ structure: DocumentStructure) {
        guard let fileURL else { return }
        let fingerprint = structure.fingerprint
        let fileName = fileURL.lastPathComponent
        let lastKnownPath = fileURL.path
        let metadataTitle = pdfDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let title = DocumentTitle.resolve(metadataTitle: metadataTitle, fileName: fileName)
        let count = pageCount
        let byteHash = cachedByteHash
        let sourceDataForMigration = sourceData

        let tocSourceRecord: TocRecord.Source = tocSource == .generated ? .generated : .native
        // `origin`/`pageY` are propagated here too (not only `id/title/
        // level/page`): `DocumentStore.updateStructure` would recover them from
        // the already saved record anyway if this snapshot lost them, but
        // carrying them is more direct and does not rely only on the defensive
        // deduplication.
        let tocEntriesSnapshot = tocEntries.map { TocEntryRecord(id: $0.id, title: $0.title, level: $0.level, page: $0.page, origin: $0.origin, pageY: $0.pageY) }
        let toc = TocRecord(source: tocSourceRecord, entries: tocEntriesSnapshot)
        let blocks = structure.blocks.map {
            BlockRecord(id: $0.id, sectionPath: $0.sectionPath, pageStart: $0.pageStart, pageEnd: $0.pageEnd, textHash: $0.textHash, words: $0.words)
        }
        let exhibits = structure.exhibits.map { ExhibitRecord(label: $0.label, page: $0.page) }

        Task { [weak self] in
            guard let self else { return }
            let registered = await AppStore.shared.registerDocument(
                fingerprint: fingerprint, byteHash: byteHash, fileName: fileName,
                lastKnownPath: lastKnownPath, title: title, pageCount: count,
                initialColorTheme: initialColorTheme, initialSummaryGranularity: initialSummaryGranularity
            )
            if registered.isNew, let legacyPage = LastPageStore.lastPage(for: sourceDataForMigration), legacyPage < count {
                await AppStore.shared.updateProgress(fingerprint: fingerprint, lastReadPage: legacyPage)
            }
            let orphans = await AppStore.shared.updateStructure(
                fingerprint: fingerprint, toc: toc, segmentationVersion: SegmentationVersion.current,
                blocks: blocks, exhibits: exhibits
            )
            guard let (finalRecord, finalAnalysis, finalAnnotations) = await AppStore.shared.loadRecordAndAnalysis(fingerprint: fingerprint) else { return }
            self.orphanBlocks = orphans
            self.applyStoreResult(fingerprint: fingerprint, record: finalRecord, analysis: finalAnalysis, annotations: finalAnnotations)
            // Fix: the record just re-read is the source of truth for the contents
            // (persistence corrected in `DocumentStore.updateStructure`, which no
            // longer lets the evaluation of this session's built-in contents alone
            // overwrite an already generated contents). Without this, a contents
            // generated in an earlier session was never republished into
            // `tocEntries`/`tocSource` when generation did not restart (because it
            // was already present): the Chapters sidebar stayed empty even though
            // the data was saved correctly.
            if !finalRecord.toc.entries.isEmpty {
                self.applyTocRecord(finalRecord.toc)
            }
            self.refreshAnalysisContext()
            self.maybeGenerateToc(structure: structure, storedToc: finalRecord.toc)
            // A document that already had a granularity chosen in an earlier
            // session immediately receives the corresponding blocks, not those of
            // the current segmentation computed above; silent (no confirmation, the
            // same automatic re-attachment logic as any other structure change).
            self.recomputeBlocksForChosenGranularityIfNeeded()
        }
    }

    // MARK: - Generated contents (SPEC §7.4, M4)

    /// Generates the contents once per document, when the built-in contents
    /// is not useful and no saved generated one exists (SPEC §5.3
    /// "Otherwise the contents is generated"). "Regenerate Contents"
    /// (`regenerateToc`) always forces a new call.
    private func maybeGenerateToc(structure: DocumentStructure, storedToc: TocRecord) {
        // "Adding a manual entry must not disable auto generation logic": "no
        // contents" must be judged on the AUTOMATIC entries only, not on
        // `entries.isEmpty` in general; a T1 added by hand to a document that
        // otherwise has no contents must not prevent automatic generation.
        guard storedToc.source != .generated, !storedToc.entries.contains(where: { $0.origin != .manual }) else { return }
        guard !structure.tocCandidates.isEmpty else { return }
        startTocGeneration(candidates: structure.tocCandidates, headings: structure.headings)
    }

    /// "Regenerate Contents" menu (SPEC §5.3): asks no confirmation, always
    /// redoes the call with the current candidates.
    func regenerateToc() {
        guard let structure else { return }
        startTocGeneration(candidates: structure.tocCandidates, headings: structure.headings)
    }

    /// `headings` (SPEC §7.3): captured at the call instead of re-reading
    /// `self.structure` inside the `Task`, so the matching
    /// (`TocHeadingMatch`) stays consistent with the very candidates just
    /// sent to Claude even if the pipeline republishes `structure` in the
    /// meantime.
    private func startTocGeneration(candidates: [TocCandidate], headings: [Heading]) {
        guard tocGenerationState != .generating else { return }
        guard let storeFingerprint else { return }
        tocGenerationState = .generating
        let title = documentRecord?.title ?? displayName
        let count = pageCount
        Task { [weak self] in
            guard let self else { return }
            let result = await TocGenerator.generate(title: title, pageCount: count, candidates: candidates)
            switch result {
            case .success(let outcome):
                let records = outcome.value.enumerated().map { index, entry -> TocEntryRecord in
                    let pageIndex = entry.page - 1
                    let pageY = TocHeadingMatch.pageY(forTitle: entry.title, pageIndex: pageIndex, headings: headings)
                    return TocEntryRecord(id: "gen-\(index)", title: entry.title, level: entry.level, page: pageIndex, pageY: pageY)
                }
                let toc = TocRecord(source: .generated, entries: records)
                await AppStore.shared.updateToc(fingerprint: storeFingerprint, toc: toc)
                if let mergedRecord = await AppStore.shared.currentRecord(fingerprint: storeFingerprint) {
                    let previousEntries = self.tocEntries
                    self.documentRecord = mergedRecord
                    self.applyTocRecord(mergedRecord.toc)
                    // Collapsed state/pin on the new entries; the manual contents' ⌘Z is no
                    // longer valid.
                    self.reconcileTocEntryState(previousEntries: previousEntries)
                }
                self.tocGenerationState = .idle
                self.refreshAnalysisContext()
                // As above in `attachStructureToStore`: a contents generated for the
                // first time or regenerated ("Regenerate Contents") immediately
                // realigns the blocks to the already chosen granularity, if any.
                self.recomputeBlocksForChosenGranularityIfNeeded()
            case .failure(let error):
                self.tocGenerationState = .failed(error.userMessage)
            }
        }
    }

    /// Not `private`: also called by `DocumentModelSummaryGranularity.swift`
    /// after a recomputation of the blocks; same type, separate file to keep
    /// files short, the same principle already used by
    /// `refreshAnalysisContext`/`applyTocRecord` above.
    func applyStoreResult(fingerprint: String, record: DocumentRecord, analysis: AnalysisRecord, annotations: AnnotationsRecord) {
        storeFingerprint = fingerprint
        documentRecord = record
        self.analysis = analysis
        // SPEC §5.13 "Reopening: they reappear with the other data within 1 s".
        let localItems = annotations.items.filter { $0.externalPDFIdentifier == nil }
        var mergedByID = Dictionary(uniqueKeysWithValues: localItems.map { ($0.id, $0) })
        for recovered in annotationsReadFromPDF.recoveredFreeAnnotations where mergedByID[recovered.id] == nil {
            mergedByID[recovered.id] = recovered
        }
        let merged = Array(mergedByID.values).sorted { $0.id < $1.id } + annotationsReadFromPDF.external
        annotationController.load(fingerprint: fingerprint, items: merged)
        if merged != annotations.items {
            Task { await AppStore.shared.updateAnnotations(fingerprint: fingerprint) { $0.items = merged } }
        }
        if record.progress.lastReadPage > 0, record.progress.lastReadPage != currentPageIndex, record.progress.lastReadPage < pageCount {
            goToPage(record.progress.lastReadPage)
        }
        if let pendingLastReadPage {
            self.pendingLastReadPage = nil
            Task { await AppStore.shared.updateProgress(fingerprint: fingerprint, lastReadPage: pendingLastReadPage) }
        }
        if let pendingColorTheme {
            self.pendingColorTheme = nil
            documentRecord?.colorTheme = pendingColorTheme
            Task { await AppStore.shared.updateColorTheme(fingerprint: fingerprint, colorTheme: pendingColorTheme) }
        }
        if let pendingCollapsedTocEntryIds {
            self.pendingCollapsedTocEntryIds = nil
            documentRecord?.collapsedTocEntryIds = pendingCollapsedTocEntryIds.sorted()
            Task { await AppStore.shared.updateCollapsedTocEntryIds(fingerprint: fingerprint, ids: pendingCollapsedTocEntryIds) }
        }
        refreshAnalysisContext()
    }

    // MARK: - Color per subject (SPEC §5.4 v2.6, §8)

    /// Effective hue of THIS document. New documents receive and save the
    /// snapshot of the Settings default; an old `documento.json` without
    /// `colorTheme` stays compatible and uses blue.
    var colorTheme: MaterialHue {
        if let pendingColorTheme { return pendingColorTheme }
        if let documentRecord { return documentRecord.colorTheme ?? .default }
        return initialColorTheme
    }

    /// "Subject color" picker in the sidebar legend (SPEC §5.4 v2.6):
    /// immediately updates the PDF (overlay), the rewrite (notification, like
    /// hover: `MarkedNSTextView` is not pure SwiftUI) and the map (pure
    /// SwiftUI, updates by itself following `@Observable`), then saves into
    /// `documento.json`.
    func setColorTheme(_ hue: MaterialHue) {
        guard colorTheme != hue else { return }
        documentRecord?.colorTheme = hue
        NotificationCenter.default.post(name: .lelePdfColorThemeChanged, object: self)
        mapDataDidChange()
        readerBridge?.invalidateOverlay()
        scheduleAutomaticPDFSaveIfEnabled()
        guard let storeFingerprint else {
            pendingColorTheme = hue
            return
        }
        pendingColorTheme = nil
        Task { await AppStore.shared.updateColorTheme(fingerprint: storeFingerprint, colorTheme: hue) }
    }

    /// Republishes `analysisController`'s context (SPEC M5a deliverable 6)
    /// from whatever updated combination of fingerprint/blocks/contents/
    /// analysis is already known: a no-op until the fingerprint is known
    /// (before the fast path or the pipeline). Not `private` (M7): also called
    /// by `DocumentModelManualToc.swift` after a manual contents change, same
    /// type, separate file to keep files short.
    func refreshAnalysisContext() {
        guard let storeFingerprint, let documentRecord else { return }
        analysisController.updateContext(
            fingerprint: storeFingerprint,
            documentTitle: documentRecord.title,
            blocks: structure?.blocks ?? [],
            exhibits: structure?.exhibits ?? [],
            analysis: analysis ?? AnalysisRecord(),
            lastAnalyzedBlockId: documentRecord.progress.lastAnalyzedBlockId,
            tocEntries: tocEntries,
            summaryGranularity: effectiveSummaryGranularity
        )
        mapDataDidChange()
        readerBridge?.invalidateOverlay()
    }

    /// To call when the window closes (SPEC §8 "batched every 500 ms", but
    /// on close it writes immediately without waiting).
    func flushStore() {
        if PDFWritePreference.isEnabled(), fileURL != nil {
            automaticPDFSaveTask?.cancel()
            automaticPDFSaveTask = nil
            performPDFSave()
        }
        guard let storeFingerprint else { return }
        Task {
            await analysisController.waitForPendingManualMarkPersistence()
            await AppStore.shared.flush(fingerprint: storeFingerprint)
        }
    }

    // MARK: - Navigation

    func goToPage(_ index: Int) {
        readerBridge?.goToPage(index)
    }

    /// "Go" menu (`NavigationCommands.swift`, "previous/next page"). Clamped,
    /// not circular, consistent with the Pages sidebar (M2), where the last
    /// page does not "wrap" to the first.
    func goToPreviousPage() {
        guard currentPageIndex > 0 else { return }
        goToPage(currentPageIndex - 1)
    }

    func goToNextPage() {
        guard currentPageIndex < pageCount - 1 else { return }
        goToPage(currentPageIndex + 1)
    }

    /// Called by the coordinator when the PDF changes page (by scrolling or
    /// by a command): persists `progress.lastReadPage` in the Store (SPEC
    /// §5.2, §8). If the fingerprint is not known yet (the fast path or the
    /// pipeline have not finished), the page waits and is applied as soon as
    /// the fingerprint arrives.
    func noteReaderPageChanged(_ index: Int) {
        guard let storeFingerprint else {
            pendingLastReadPage = index
            return
        }
        Task { await AppStore.shared.updateProgress(fingerprint: storeFingerprint, lastReadPage: index) }
    }

    // MARK: - Zoom

    func zoomIn() {
        if mapExpanded {
            mapZoom = min(3.5, mapZoom + 0.15)
        } else {
            readerBridge?.zoomIn()
        }
    }

    func zoomOut() {
        if mapExpanded {
            mapZoom = max(0.45, mapZoom - 0.15)
        } else {
            readerBridge?.zoomOut()
        }
    }

    func zoomActualSize() {
        if mapExpanded {
            mapZoom = 1
        } else {
            readerBridge?.zoomToActualSize()
        }
    }

    // MARK: - Panels (SPEC §5.1)

    func toggleSidebar() { sidebarVisible.toggle() }
    func toggleRightPanel() { rightPanelVisible.toggle() }

    func openExpandedMap(initialZoom: Double = 1) {
        mapZoom = min(3.5, max(0.45, initialZoom))
        mapExpanded = true
    }

    func closeExpandedMap() {
        mapExpanded = false
        setHover(termId: nil)
    }

    /// Integration point for M7: after a manual mutation of `AnalysisRecord`,
    /// call this method to rebuild the map. The real rebuild of the map data
    /// (`MapDataExtractor`, potentially over the whole book) starts only
    /// 200 ms after the LAST change, not on every single mark
    /// added/changed/removed: before, every mutation immediately bumped
    /// `mapDataRevision`, and `MapSidebarView`/`MapExpandedView`
    /// (`.task(id:)`) cancelled the previous computation to start a new one
    /// right away: with the map open, inserting/removing marks in quick
    /// succession restarted that work at every touch instead of waiting for
    /// the user to stop.
    private var mapDataDebounceTask: Task<Void, Never>?

    func mapDataDidChange() {
        mapDataDebounceTask?.cancel()
        mapDataDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.mapDataRevision &+= 1
        }
    }

    /// Click on a node: reaches the first exact mark in the PDF when the
    /// structure is available, otherwise at least the page. M6 also brings
    /// the right-hand card directly to the reading line, even when "Follow
    /// the PDF" is off (SPEC §5.3/§5.8).
    func navigateToMapNode(_ node: MapNode) {
        guard let occurrence = node.firstOccurrence else { return }
        var reachedExactPDFSelection = false
        if let block = analysisController.context?.blocks.first(where: { $0.id == occurrence.blockId }) {
            let range = NSRange(location: occurrence.range.start, length: occurrence.range.length)
            if let selection = BlockSelectionResolver.selections(
                for: range, in: block, document: pdfDocument
            ).first {
                readerBridge?.go(to: selection)
                reachedExactPDFSelection = true
            }
        }
        if !reachedExactPDFSelection { goToPage(occurrence.page) }

        let rowID = "b-\(occurrence.blockId)"
        if let segment = syncCoordinator.segments.first(where: { $0.id == rowID }) {
            syncCoordinator.scrollToShow(side: .panel, topDownY: segment.panelStart)
        }
    }

    // MARK: - Search (SPEC §5.10)

    /// While a row of the right panel is being edited in place,
    /// ⌘F/⌘G/⇧⌘G do nothing ("works from any focus except inside an inline
    /// edit"); used by the `.disabled` of the commands in
    /// `App/DocumentCommands.swift`.
    var isSearchAvailable: Bool { analysisController.isEditingAnyLine == false }

    func focusSearch() {
        guard isSearchAvailable else { return }
        searchFocusToken += 1
    }

    /// "Esc closes": clears the query (hides results/highlights) and gives
    /// focus back to the window, the same principle as the single Esc command
    /// already used for chat/map (`closeTransientOverlays`), here extended to
    /// include search.
    func closeSearch() {
        searchQuery = ""
        searchResults = []
        rewriteSearchBlockIds = []
        currentSearchResultIndex = nil
        readerBridge?.setHighlightedSelections(nil)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Page range of the current chapter for the "Chapter" scope (SPEC
    /// §5.10): without contents, the scope falls back to the whole PDF.
    private var currentChapterRange: ClosedRange<Int>? {
        TocNavigation.chapterPageRange(entries: tocEntries, page: currentPageIndex, pageCount: pageCount)
    }

    func runSearch() {
        searchTask?.cancel()
        let query = searchQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            rewriteSearchBlockIds = []
            currentSearchResultIndex = nil
            readerBridge?.setHighlightedSelections(nil)
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.performSearch(query)
        }
    }

    private func performSearch(_ query: String) {
        let range = searchScope == .capitolo ? currentChapterRange : nil
        let results = SearchService.find(query, in: pdfDocument, pageRange: range)
        searchResults = results
        // Right panel results, in document order, AFTER those of the PDF: one
        // block = one result if its resolved text contains the query (counting
        // at block level, kept simple on purpose).
        rewriteSearchBlockIds = (analysisController.context?.blocks ?? []).compactMap { block in
            guard let card = analysisController.cardData(for: block.id) else { return nil }
            return RewriteSearch.matches(query, in: card.rewrite) ? block.id : nil
        }
        currentSearchResultIndex = searchTotalCount == 0 ? nil : 0
        applySearchHighlight()
    }

    private func applySearchHighlight() {
        readerBridge?.setHighlightedSelections(searchResults.isEmpty ? nil : searchResults)
        guard let index = currentSearchResultIndex else { return }
        if searchResults.indices.contains(index) {
            readerBridge?.go(to: searchResults[index])
            return
        }
        let rewriteIndex = index - searchResults.count
        guard rewriteSearchBlockIds.indices.contains(rewriteIndex) else { return }
        goToRewriteSearchMatch(blockId: rewriteSearchBlockIds[rewriteIndex])
    }

    /// A "panel row" result ALSO brings the PDF to the block's page
    /// (`goToPage`, consistent with every other navigation in the app) in
    /// addition to scrolling the panel; the same pattern already used by the
    /// chat's "Go to the passage" (`ChatCitationNavigation`/above in this
    /// file): `syncCoordinator.scrollToShow(side: .panel, ...)` on the
    /// `"b-<blockId>"` segment.
    private func goToRewriteSearchMatch(blockId: String) {
        if let block = analysisController.context?.blocks.first(where: { $0.id == blockId }) {
            goToPage(block.pageStart)
        }
        let rowID = "b-\(blockId)"
        if let segment = syncCoordinator.segments.first(where: { $0.id == rowID }) {
            syncCoordinator.scrollToShow(side: .panel, topDownY: segment.panelStart)
        }
    }

    func searchNext() {
        guard searchTotalCount > 0 else { return }
        let next = (currentSearchResultIndex ?? -1) + 1
        currentSearchResultIndex = next % searchTotalCount
        applySearchHighlight()
    }

    func searchPrevious() {
        guard searchTotalCount > 0 else { return }
        let previous = (currentSearchResultIndex ?? 0) - 1
        currentSearchResultIndex = ((previous % searchTotalCount) + searchTotalCount) % searchTotalCount
        applySearchHighlight()
    }

    // MARK: - Pages sidebar (SPEC §5.3, M5b)

    /// Full dot if all the blocks touching the page are analyzed, half dot if
    /// only some, none if zero (or if the page is touched by no block).
    func pageAnalysisStatus(at index: Int) -> PageAnalysisStatus {
        guard let blocks = structure?.blocks, !blocks.isEmpty else { return .none }
        return PerfProbe.measure("model.pageAnalysisStatus") {
            let touching = blocks.filter { $0.pageStart <= index && index <= $0.pageEnd }
            guard !touching.isEmpty else { return .none }
            let analyzedCount = touching.filter { analysisController.blockState($0.id) == .analyzed }.count
            return PageAnalysisStatus.compute(analyzedCount: analyzedCount, totalTouching: touching.count)
        }
    }

    var breadcrumb: String? {
        TocNavigation.breadcrumb(entries: tocEntries, page: currentPageIndex)
    }
}
