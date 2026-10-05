import AppKit
import Foundation
@preconcurrency import PDFKit
import SwiftUI
import Testing
@testable import LelePdf

/// F17 area 3: review of the sidebar and the contents. Each fix has its test
/// here; where the behavior is visual or interactive the test goes through the
/// REAL view as the app composes it (`Sidebar`/`ChaptersSidebar` inside
/// `ThreePaneLayout` in an `NSWindow`, a row pressed through its button's
/// accessibility action, arrow keys as real `NSEvent`s delivered to the
/// window): the lesson from area 2, where a reduced scene had missed a
/// feature that was switched off in the real card.
extension HeavyTestSuites {
@MainActor
@Suite("F17 area 3: sidebar and contents (pin, ⌘Z, ids, collapsed state, ordering, real views)", .serialized)
struct SidebarReviewF17Tests {
    // MARK: - Model and scenes

    private func entry(_ id: String, _ title: String, level: Int, page: Int, pageY: Double? = nil, origin: TocEntryOrigin? = nil) -> TocEntryRecord {
        TocEntryRecord(id: id, title: title, level: level, page: page, origin: origin, pageY: pageY)
    }

    /// Test "generated" contents: two chapters with one child each.
    private var sampleToc: [TocEntryRecord] {
        [
            entry("gen-0", "Alpha chapter", level: 1, page: 0),
            entry("gen-1", "Beta section", level: 2, page: 1),
            entry("gen-2", "Gamma chapter", level: 1, page: 2),
            entry("gen-3", "Delta section", level: 2, page: 2),
        ]
    }

    /// A synthetic three-page PDF and an in-memory `documentRecord` (no Store:
    /// `storeFingerprint` stays `nil`, edits to the contents stay local, as in
    /// the window before the fingerprint is known).
    private func makeModel(toc: [TocEntryRecord]? = nil, pageCount: Int = 3) throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeMultiPageTextPDF(pageCount: pageCount, pageSize: CGSize(width: 300, height: 400), fileName: "f17-sidebar-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "f17-sidebar-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
        var record = StoreFixtures.sampleDocumentRecord()
        record.pageCount = pageCount
        record.toc = TocRecord(source: .generated, entries: toc ?? sampleToc)
        model.documentRecord = record
        model.applyTocRecord(record.toc)
        model.setColorTheme(.blu)
        return model
    }

    private func cleanup(_ model: DocumentModel) {
        if let fileURL = model.fileURL { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    }

    /// A real `PDFView` attached to the model (`PDFReaderBridge` +
    /// `ScrollSyncCoordinator`), like `TocHighlightAfterNavigationTests`:
    /// 300×200 viewport on 300×400 pages, so it really scrolls.
    private func attachRealPDFView(_ model: DocumentModel) throws -> NSWindow {
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
        let window = NSWindow(contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pdfView
        window.layoutIfNeeded()
        let bridge = PDFReaderBridge(pdfView: pdfView)
        model.readerBridge = bridge
        let scrollView = try #require(bridge.enclosingScrollView)
        model.syncCoordinator.attachPDF(scrollView: scrollView, model: model)
        return window
    }

    private func makeUndoManager(_ model: DocumentModel) -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.analysisController.undoManager = undoManager
        return undoManager
    }

    private func grouped(_ undoManager: UndoManager, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
    }

    private struct Scene {
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
    }

    /// The REAL composition: `ThreePaneLayout` (sidebar, reader with
    /// `PDFKitView` and overlay, right panel) in an `NSWindow`, like
    /// `PerfBenchHost`; never `orderFront`.
    private func hostThreePane(_ model: DocumentModel, size: CGSize = CGSize(width: 1100, height: 700)) async throws -> Scene {
        let hosting = NSHostingView(rootView: AnyView(ThreePaneLayout().environment(model).frame(width: size.width, height: size.height)))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            if model.readerBridge?.enclosingScrollView != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try await pump(hosting, seconds: 0.4)
        return Scene(window: window, hosting: hosting)
    }

    private func hostSidebar(_ model: DocumentModel, width: CGFloat = 264, height: CGFloat = 520) async throws -> Scene {
        let hosting = NSHostingView(rootView: AnyView(Sidebar().environment(model).frame(width: width, height: height)))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await pump(hosting, seconds: 0.3)
        return Scene(window: window, hosting: hosting)
    }

    /// A REAL run loop turn (window events, `NSTrackingArea`, scroll
    /// notifications), synchronous, like `RewritePanelReviewF17Tests.pump`:
    /// `RunLoop.run(until:)` cannot be called from an `async` context.
    private func spin(_ hosting: NSView, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        hosting.layoutSubtreeIfNeeded()
    }

    /// Alternates run loop turns and real suspensions: only a suspension
    /// yields the MainActor to the model's `Task`s (saves, the thumbnails'
    /// `.task`), only the run loop delivers AppKit events.
    private func pump(_ hosting: NSView, seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            spin(hosting, seconds: 0.02)
            try await Task.sleep(for: .milliseconds(10))
        }
        hosting.layoutSubtreeIfNeeded()
    }

    // MARK: - The AppKit hierarchy of the real composition

    /// The accessibility tree of `NSHostingView` is EMPTY under `xctest` (no
    /// AX client attached: 0 children even with the window on screen,
    /// measured), so the real rows are reached through the `NSView` hierarchy
    /// that SwiftUI really mounts: the contents list is a `HostingScrollView`
    /// in the sidebar column and each row (a focusable `Button`) has a
    /// `_FocusRingView` with the EXACT frame of the row (x = indent, height
    /// 26), so the mounted rows can be counted and the indent read. A
    /// synthetic CLICK, however, does not reach a SwiftUI `Button` under
    /// `xctest` (measured, seven ways: `window.sendEvent`, `NSApp.sendEvent`,
    /// direct `mouseDown` on the hit view or on the root, a recognizer, a root
    /// that accepts first mouse, an on-screen window; the test process cannot
    /// be activated, `NSApp.activate` → `isActive == false`, the window never
    /// becomes key): the `ChapterRow.onNavigate → goToTocEntry` and
    /// `.onKeyPress → collapse/expandSelectedTocEntry` wiring stays verified
    /// by reading, and here the same action the row/key calls is invoked,
    /// observing the effect in the real view. Same limit as stated elsewhere
    /// in the suite.
    private func allViews(_ root: NSView) -> [NSView] {
        var result: [NSView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            result.append(view)
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    private func className(_ view: NSView) -> String { String(describing: type(of: view)) }

    /// The contents list (SwiftUI `ScrollView` → `HostingScrollView`) inside
    /// the sidebar column (x < sidebar width).
    private func sidebarListScrollView(_ hosting: NSView) -> NSView? {
        allViews(hosting).first {
            className($0).contains("HostingScrollView") && $0.convert($0.bounds, to: nil).minX < DSMetrics.sidebarWidth - 1
        }
    }

    /// The mounted rows of the list, top to bottom (window coordinates: y
    /// grows upward, hence descending order).
    private func rowProxies(in list: NSView) -> [NSView] {
        allViews(list).filter { className($0) == "_FocusRingView" && $0.frame.height == DSMetrics.indexRowHeight }
            .sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
    }

    /// Number of MOUNTED rows: from the height of the list's `DocumentView`
    /// (rows × 26 + 8 vertical padding); SwiftUI recycles the
    /// `_FocusRingView`s of rows that disappeared (they keep stale frames), so
    /// counting them would always give the maximum ever mounted.
    private func sidebarRowCount(_ hosting: NSView) -> Int {
        guard let list = sidebarListScrollView(hosting), let document = allViews(list).first(where: { className($0) == "DocumentView" }) else { return 0 }
        return Int(((document.frame.height - 8) / DSMetrics.indexRowHeight).rounded())
    }

    private func sidebarRows(_ hosting: NSView) -> [NSView] {
        guard let list = sidebarListScrollView(hosting) else { return [] }
        return rowProxies(in: list)
    }

    /// The Pages | Contents | Map selector (`SwiftUISegmentedControl`):
    /// present only if the sidebar is mounted.
    private func sidebarTabPicker(_ hosting: NSView) -> NSView? {
        allViews(hosting).first { className($0) == "SwiftUISegmentedControl" && $0.convert($0.bounds, to: nil).minX < DSMetrics.sidebarWidth }
    }

    private func viewTreeSummary(_ hosting: NSView) -> String {
        allViews(hosting).map { view in
            let f = view.convert(view.bounds, to: nil)
            return "\(className(view)) x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))"
        }.prefix(60).joined(separator: "; ")
    }

    private func visibleIds(_ model: DocumentModel) -> [String] {
        let depths = ManualToc.indentDepths(levels: model.tocEntries.map(\.level))
        let visible = TocCollapse.visibleIndices(ids: model.tocEntries.map(\.id), depths: depths, collapsed: model.collapsedTocEntryIds)
        return model.tocEntries.indices.filter { visible[$0] }.map { model.tocEntries[$0].id }
    }

    // MARK: - Entries without pageY: the pin survives the page jump

    @Test("two entries without pageY on the same page: after the click the clicked one stays highlighted (real PDFView)")
    func legacyEntriesSamePageKeepClickedHighlight() throws {
        let model = try makeModel(toc: [
            entry("n0", "Cover", level: 1, page: 0),
            entry("n1", "First on page two", level: 1, page: 1),
            entry("n2", "Second on page two", level: 2, page: 1),
        ])
        defer { cleanup(model) }
        let window = try attachRealPDFView(model)
        defer { closeTestWindow(window) }

        model.goToTocEntry(model.tocEntries[1])
        #expect(model.pinnedTocEntryID == "n1", "the page-only jump released the pin that had just been set")
        #expect(model.currentTocEntry?.id == "n1", "expected 'n1' right after the click, found \(model.currentTocEntry?.id ?? "nil")")
        #expect(model.currentPageIndex == 1)

        model.goToTocEntry(model.tocEntries[2])
        #expect(model.currentTocEntry?.id == "n2")

        // A REAL scroll releases the pin as before.
        let pdfScrollView = try #require(model.syncCoordinator.pdfScrollViewForMeasurement)
        DocumentSpace.scroll(pdfScrollView, topDownTop: DocumentSpace.maxScrollTopDown(pdfScrollView))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(model.pinnedTocEntryID == nil)
    }

    // MARK: - Rename/Remove are synchronous and undoable

    @Test("Rename and Remove go through the window's real UndoManager: ⌘Z/⇧⌘Z undo and redo them")
    func renameAndRemoveAreUndoableWithTheWindowUndoManager() throws {
        let model = try makeModel()
        defer { cleanup(model) }
        let undoManager = makeUndoManager(model)

        grouped(undoManager) { model.renameTocEntry(id: "gen-1", title: "Beta  renamed\n") }
        let renamed = try #require(model.tocEntries.first { $0.title == "Beta renamed" }, "the rename must be visible immediately, without a round trip through the Store")
        #expect(renamed.isManual)
        #expect(undoManager.canUndo)
        #expect(model.tocEntries.map(\.id).count == 4, "the tombstone must not appear")

        undoManager.undo()
        #expect(model.tocEntries.contains { $0.id == "gen-1" && $0.title == "Beta section" })
        #expect(!model.tocEntries.contains { $0.title == "Beta renamed" })
        undoManager.redo()
        #expect(model.tocEntries.contains { $0.title == "Beta renamed" })

        grouped(undoManager) { model.removeTocEntry(id: renamed.id) }
        #expect(!model.tocEntries.contains { $0.id == renamed.id }, "Remove must hide the entry immediately")
        undoManager.undo()
        #expect(model.tocEntries.contains { $0.id == renamed.id }, "⌘Z must bring the removed entry back")
    }

    @Test("⌘Z on an earlier edit does not undo a rename made afterwards")
    func undoOfAnEarlierEditKeepsALaterRename() throws {
        let model = try makeModel()
        defer { cleanup(model) }
        let undoManager = makeUndoManager(model)

        grouped(undoManager) { model.changeTocEntryLevel(id: "gen-0", level: 2) }
        grouped(undoManager) { model.renameTocEntry(id: "gen-1", title: "Beta renamed") }
        #expect(model.tocEntries.contains { $0.title == "Alpha chapter" && $0.level == 2 })
        #expect(model.tocEntries.contains { $0.title == "Beta renamed" })

        undoManager.undo() // undoes ONLY the rename
        #expect(model.tocEntries.contains { $0.title == "Beta section" })
        #expect(model.tocEntries.contains { $0.title == "Alpha chapter" && $0.level == 2 }, "the earlier level change must stay")

        undoManager.undo()
        #expect(model.tocEntries.contains { $0.id == "gen-0" && $0.level == 1 })
    }

    @Test("a contents edit updates the entries seen by the analysis without clearing the marks' ⌘Z")
    func tocEditUpdatesAnalysisTocWithoutClearingMarkUndo() throws {
        let model = try makeModel()
        defer { cleanup(model) }
        let text = "Alpha chapter text for the block"
        let block = TextBlock(id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0, cleanText: text, textHash: "h1", words: 6, spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
        model.analysisController.updateContext(fingerprint: "fp-f17a3", documentTitle: "T", blocks: [block], exhibits: [], analysis: AnalysisRecord(), lastAnalyzedBlockId: nil, tocEntries: model.tocEntries)
        model.analysisController.manualMarksUndoStack.record(ManualMarkEdit(blockId: "b1"))
        #expect(model.analysisController.manualMarksUndoStack.canUndo)

        model.renameTocEntry(id: "gen-0", title: "Alpha renamed")
        #expect(model.analysisController.allTocEntries.contains { $0.title == "Alpha renamed" }, "titles among the cards/labels must see the rename immediately")
        #expect(model.analysisController.level1TocEntries.count == 2)
        #expect(model.analysisController.manualMarksUndoStack.canUndo, "a contents edit is not a new context: the marks' ⌘Z stays")
    }

    // MARK: - The collapsed state and the pin follow the entry

    @Test("renaming or changing the level of a collapsed chapter leaves it collapsed (and ⌘Z brings it back collapsed)")
    func renamingACollapsedChapterKeepsItCollapsed() throws {
        let model = try makeModel()
        defer { cleanup(model) }
        let undoManager = makeUndoManager(model)
        model.toggleTocEntryCollapsed(id: "gen-0")
        model.pinnedTocEntryID = "gen-0"
        #expect(visibleIds(model) == ["gen-0", "gen-2", "gen-3"])

        grouped(undoManager) { model.renameTocEntry(id: "gen-0", title: "Alpha renamed") }
        let renamed = try #require(model.tocEntries.first { $0.title == "Alpha renamed" })
        #expect(renamed.id != "gen-0")
        #expect(model.collapsedTocEntryIds == [renamed.id], "the collapsed state stayed on the invisible tombstone: the chapter expanded")
        #expect(model.pinnedTocEntryID == renamed.id)
        #expect(visibleIds(model) == [renamed.id, "gen-2", "gen-3"])

        undoManager.undo()
        #expect(model.collapsedTocEntryIds == ["gen-0"])
        #expect(model.pinnedTocEntryID == "gen-0")
        #expect(visibleIds(model) == ["gen-0", "gen-2", "gen-3"])

        undoManager.redo()
        #expect(model.collapsedTocEntryIds == [renamed.id])

        // Level change on a collapsed entry: same mechanism.
        model.toggleTocEntryCollapsed(id: "gen-2")
        grouped(undoManager) { model.changeTocEntryLevel(id: "gen-2", level: 2) }
        let changed = try #require(model.tocEntries.first { $0.title == "Gamma chapter" })
        #expect(changed.level == 2)
        #expect(model.collapsedTocEntryIds.contains(changed.id))
        #expect(!model.collapsedTocEntryIds.contains("gen-2"))
    }

    @Test("regenerated contents: the collapsed state and the pin follow page+title, the rest drops, the contents ⌘Z is emptied")
    func regeneratedContentsRemapCollapsedStateByPageAndTitle() throws {
        let model = try makeModel()
        defer { cleanup(model) }
        let undoManager = makeUndoManager(model)
        grouped(undoManager) { model.changeTocEntryLevel(id: "gen-3", level: 3) }
        #expect(undoManager.canUndo)
        model.toggleTocEntryCollapsed(id: "gen-0")
        model.toggleTocEntryCollapsed(id: "gen-2")
        model.pinnedTocEntryID = "gen-2"

        // "Regenerate contents": the positional ids change entry: "Alpha"
        // disappears, "Gamma" becomes gen-1; the manual T3 (manual-1) keeps its id.
        let previous = model.tocEntries
        let manual = try #require(model.documentRecord?.toc.entries.first { $0.origin == .manual && $0.removed != true })
        let regenerated = TocRecord(source: .generated, entries: [
            entry("gen-0", "Intro", level: 1, page: 0),
            entry("gen-1", "Gamma chapter", level: 1, page: 2),
            entry("gen-2", "Epsilon", level: 2, page: 2),
            manual,
        ])
        model.documentRecord?.toc = regenerated
        model.applyTocRecord(regenerated)
        model.reconcileTocEntryState(previousEntries: previous)

        #expect(model.collapsedTocEntryIds == ["gen-1"], "Gamma (collapsed) is now gen-1; Alpha is gone and its state drops")
        #expect(model.pinnedTocEntryID == "gen-1")
        #expect(!undoManager.canUndo, "the manual contents ⌘Z described lists that no longer exist")
        #expect(!model.manualTocUndoStack.canUndo)
        #expect(visibleIds(model) == ["gen-0", "gen-1"], "Epsilon and the manual T3 under Gamma stay hidden")
    }

    @Test("TocEntriesEdit.idRemap: level change and rename map the old id to the new one; add and remove do not")
    func idRemapFollowsEditedEntries() {
        var entries = [entry("gen-0", "Alpha", level: 1, page: 0, pageY: 700), entry("gen-1", "Beta", level: 2, page: 0, pageY: 500)]
        let before = entries
        ManualToc.rename(id: "gen-0", to: "Alpha renamed", entries: &entries)
        let renamedId = ManualToc.visible(entries).first { $0.title == "Alpha renamed" }!.id
        #expect(TocEntriesEdit(before: before, after: entries).idRemap == ["gen-0": renamedId])

        var levelled = before
        ManualToc.changeLevel(id: "gen-1", to: 3, entries: &levelled)
        let levelledId = ManualToc.visible(levelled).first { $0.title == "Beta" }!.id
        #expect(TocEntriesEdit(before: before, after: levelled).idRemap == ["gen-1": levelledId])

        var removed = before
        ManualToc.remove(id: "gen-0", entries: &removed)
        #expect(TocEntriesEdit(before: before, after: removed).idRemap.isEmpty)

        let added = before + [entry("manual-9", "New", level: 1, page: 2, origin: .manual)]
        #expect(TocEntriesEdit(before: before, after: added).idRemap.isEmpty)
    }

    // MARK: - Duplicate ids after "Regenerate contents"

    @Test("merge: a generated id that collides with a tombstone gets a suffix, and Remove hits the entry shown")
    func mergeKeepsIdsUniqueWhenARegeneratedIdCollidesWithATombstone() {
        var entries = [entry("gen-0", "Old chapter", level: 1, page: 0), entry("gen-1", "Second", level: 1, page: 3)]
        ManualToc.remove(id: "gen-0", entries: &entries)
        let manual = entries.filter { $0.origin == .manual }
        let merged = ManualToc.merge(manual: manual, newAuto: [
            entry("gen-0", "Brand new title", level: 1, page: 5),
            entry("gen-1", "Second", level: 1, page: 3),
        ])
        #expect(Set(merged.map(\.id)).count == merged.count, "duplicate ids: \(merged.map(\.id))")
        let shown = ManualToc.visible(merged)
        #expect(shown.map(\.title) == ["Second", "Brand new title"])
        let newId = shown.first { $0.title == "Brand new title" }!.id
        #expect(newId != "gen-0")

        var afterRemove = merged
        ManualToc.remove(id: newId, entries: &afterRemove)
        #expect(!ManualToc.visible(afterRemove).contains { $0.title == "Brand new title" }, "`firstIndex` used to land on the tombstone and the entry stayed")
    }

    // MARK: - Entries on the same title line

    @Test("a manual entry on the same line as a generated title nests under it, not above it")
    func entriesOnTheSameTitleLineNestUnderTheHigherLevel() {
        let auto = entry("gen-0", "3. Strategy", level: 1, page: 4, pageY: 702.0)
        let manual = entry("manual-1", "3. Strategy overview", level: 2, page: 4, pageY: 703.4, origin: .manual)
        let sorted = ManualToc.sorted([manual, auto])
        #expect(sorted.map(\.id) == ["gen-0", "manual-1"])
        #expect(ManualToc.indentDepths(for: sorted) == [0, 1])

        // Same rule for the current entry (a single ordering).
        let display = sorted.map { TocEntry(id: $0.id, title: $0.title, level: $0.level, page: $0.page, origin: $0.origin, pageY: $0.pageY) }
        #expect(TocNavigation.currentEntry(entries: display, page: 4, pageY: 690)?.id == "manual-1")

        // No fixed step: even straddling a multiple of 4 pt (where the first,
        // "stepped" draft separated them) the two entries are the same line;
        // at 3.5 pt they are distinct lines and position wins.
        let straddle = ManualToc.sorted([entry("m", "Sub", level: 2, page: 0, pageY: 702.1, origin: .manual), entry("g", "Chap", level: 1, page: 0, pageY: 701.9)])
        #expect(straddle.map(\.id) == ["g", "m"])
        let apart = ManualToc.sorted([entry("m", "Sub", level: 2, page: 0, pageY: 703.5, origin: .manual), entry("g", "Chap", level: 1, page: 0, pageY: 700)])
        #expect(apart.map(\.id) == ["m", "g"])
    }

    @Test("with equal ids (document saved before the duplicate-id fix) Rename/Remove/Change level hit the visible record, not the tombstone")
    func editsPreferTheVisibleRecordWhenAnIdIsDuplicated() {
        var tombstone = entry("gen-0", "Old chapter", level: 1, page: 0, origin: .manual)
        tombstone.removed = true
        let stored = [tombstone, entry("gen-0", "Brand new title", level: 1, page: 5), entry("gen-1", "Second", level: 1, page: 3)]

        var renamed = stored
        ManualToc.rename(id: "gen-0", to: "Renamed", entries: &renamed)
        #expect(ManualToc.visible(renamed).map(\.title).sorted() == ["Renamed", "Second"], "the rename landed on the tombstone: \(ManualToc.visible(renamed).map(\.title))")

        var removed = stored
        ManualToc.remove(id: "gen-0", entries: &removed)
        #expect(ManualToc.visible(removed).map(\.title) == ["Second"])

        var levelled = stored
        ManualToc.changeLevel(id: "gen-0", to: 2, entries: &levelled)
        #expect(ManualToc.visible(levelled).first { $0.title == "Brand new title" }?.level == 2)
    }

    @Test("two distinct headings (at least one line apart) keep document order whatever the level")
    func distinctHeadingsKeepDocumentOrderRegardlessOfLevel() {
        let lower = entry("a", "1.1 Section", level: 2, page: 0, pageY: 520)
        let higher = entry("b", "2. Chapter", level: 1, page: 0, pageY: 508)
        #expect(ManualToc.sorted([higher, lower]).map(\.id) == ["a", "b"])
        #expect(ManualToc.sorted([lower, higher]).map(\.id) == ["a", "b"])
        // Without pageY the arrival order stays (legacy entries, M7).
        let legacyA = entry("la", "A", level: 2, page: 1)
        let legacyB = entry("lb", "B", level: 1, page: 1)
        #expect(ManualToc.sorted([legacyA, legacyB]).map(\.id) == ["la", "lb"])
    }

    // MARK: - No republishing of an unchanged page

    @Test("updateCurrentReadingPosition does not reassign currentPageIndex if the page did not change")
    func readingPositionUpdateDoesNotRepublishAnUnchangedPage() throws {
        let model = try makeModel()
        defer { cleanup(model) }
        let window = try attachRealPDFView(model)
        defer { closeTestWindow(window) }
        model.updateCurrentReadingPosition()
        let page = model.currentPageIndex

        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking {
            _ = model.currentPageIndex
        } onChange: {
            flag.fired = true
        }
        model.updateCurrentReadingPosition()
        #expect(model.currentPageIndex == page)
        #expect(!flag.fired, "a scroll tick without a page change used to re-evaluate every observer of currentPageIndex")
    }

    @Test("real sidebar, Pages tab: a position reading without a page change re-evaluates no thumbnail")
    func realPagesTabRowsAreNotReevaluatedWithoutAPageChange() async throws {
        let model = try makeModel(pageCount: 6)
        defer { cleanup(model) }
        let pdfWindow = try attachRealPDFView(model)
        defer { closeTestWindow(pdfWindow) }
        model.sidebarTab = .pagine
        let scene = try await hostSidebar(model)
        defer { closeTestWindow(scene.window) }

        PerfProbe.isEnabled = true
        defer { PerfProbe.isEnabled = false }
        try await pump(scene.hosting, seconds: 0.3)
        PerfProbe.reset()
        for _ in 0 ..< 5 {
            model.updateCurrentReadingPosition()
            try await pump(scene.hosting, seconds: 0.05)
        }
        let rows = PerfProbe.snapshot(reset: true)["swiftui.ThumbnailRow.body"]?.count ?? 0
        #expect(rows == 0, "\(rows) re-evaluations of ThumbnailRow.body without the page having changed")

        // Control: a real page change still re-evaluates them.
        model.goToPage(3)
        try await pump(scene.hosting, seconds: 0.2)
        model.updateCurrentReadingPosition()
        try await pump(scene.hosting, seconds: 0.2)
        let afterJump = PerfProbe.snapshot(reset: true)["swiftui.ThumbnailRow.body"]?.count ?? 0
        #expect(afterJump > 0)
    }

    // MARK: - The Contents tab is not rebuilt entirely on every tick

    @Test("real sidebar, Contents tab: a tick that does not change the current entry re-evaluates the list but NOT the whole tab (menus included) nor the rows; an entry change redoes only the two highlight rows")
    func realContentsRowsAreNotReevaluatedWhenTheCurrentEntryDoesNotChange() async throws {
        let model = try makeModel(pageCount: 6)
        defer { cleanup(model) }
        let pdfWindow = try attachRealPDFView(model)
        defer { closeTestWindow(pdfWindow) }
        model.sidebarTab = .indice
        let scene = try await hostSidebar(model)
        defer { closeTestWindow(scene.window) }
        try #require(sidebarRowCount(scene.hosting) == 4)
        let pdfScrollView = try #require(model.syncCoordinator.pdfScrollViewForMeasurement)

        PerfProbe.isEnabled = true
        defer { PerfProbe.isEnabled = false }
        try await pump(scene.hosting, seconds: 0.3)
        PerfProbe.reset()
        // Three ticks inside the first page (400 pt tall, viewport 200): the
        // current entry stays "Alpha chapter", only the position changes.
        for top in [40.0, 80.0, 120.0] {
            DocumentSpace.scroll(pdfScrollView, topDownTop: top)
            try await pump(scene.hosting, seconds: 0.1)
        }
        #expect(model.currentTocEntry?.id == "gen-0")
        let snapshot = PerfProbe.snapshot(reset: true)
        let lists = snapshot["swiftui.IndexPanel.list"]?.count ?? 0
        let rows = snapshot["swiftui.ChapterRow.body"]?.count ?? 0
        let wholeTab = snapshot["swiftui.ChaptersSidebar.body"]?.count ?? 0
        #expect(lists >= 1, "the list must have seen the scrolling (currentReadingPageY)")
        #expect(wholeTab == 0, "\(wholeTab) re-evaluations of the WHOLE Contents tab (header with Menu, Summarise by row) for three scroll ticks")
        #expect(rows == 0, "\(rows) re-evaluations of ChapterRow.body without the current entry having changed (list re-evaluated \(lists) times)")

        // Control: scrolling to page 2 changes the current entry (Beta): the
        // two highlight rows are redone, not all four.
        DocumentSpace.scroll(pdfScrollView, topDownTop: 420)
        try await pump(scene.hosting, seconds: 0.2)
        #expect(model.currentTocEntry?.id == "gen-1")
        let afterChange = PerfProbe.snapshot(reset: true)["swiftui.ChapterRow.body"]?.count ?? 0
        #expect(afterChange > 0 && afterChange <= 2, "expected 1-2 re-evaluated rows, found \(afterChange)")
    }

    // MARK: - Real composition: ThreePaneLayout in a window

    @Test("real composition (ThreePaneLayout in a window): four mounted rows with T1/T2 indents and fixed height; the row's action takes the real PDF there, pins the entry and highlights it")
    func realContentsRowsAndNavigationPinAndHighlight() async throws {
        // 8 pages: with 3 pages of 400 pt in a reader 628 tall, page 3 could
        // never sit at the top (the page visible at the top would stay page 2).
        let model = try makeModel(pageCount: 8)
        defer { cleanup(model) }
        model.sidebarTab = .indice
        let scene = try await hostThreePane(model)
        defer { closeTestWindow(scene.window) }
        try #require(model.readerBridge?.enclosingScrollView != nil, "PDFKitView not mounted by the real composition")
        try #require(sidebarTabPicker(scene.hosting) != nil, Comment(rawValue: "sidebar missing: \(viewTreeSummary(scene.hosting))"))
        let rows = sidebarRows(scene.hosting)
        try #require(rows.count == 4, Comment(rawValue: "expected 4 mounted rows (Alpha, Beta, Gamma, Delta), found \(rows.count): \(viewTreeSummary(scene.hosting))"))
        #expect(sidebarRowCount(scene.hosting) == 4)
        // Readable hierarchy (quality criterion 5.3): a T2 is indented 12 pt
        // relative to the T1 that precedes it (`ChapterRow`, `depth * 12`),
        // all rows at the same height.
        let xs = rows.map { $0.convert($0.bounds, to: nil).minX }
        #expect(xs[1] - xs[0] == 12 && xs[3] - xs[2] == 12, "unexpected T1/T2 indents: \(xs)")
        #expect(xs[0] == xs[2])
        #expect(rows.allSatisfy { $0.frame.height == DSMetrics.indexRowHeight })

        // The action of the third row ("Gamma chapter", page 3) on the REAL
        // PDFView mounted by PDFKitView inside ThreePaneLayout.
        model.goToTocEntry(model.tocEntries[2])
        try await pump(scene.hosting, seconds: 0.3)
        #expect(model.pinnedTocEntryID == "gen-2")
        #expect(model.currentTocEntry?.id == "gen-2")
        #expect(model.currentPageIndex == 2)

        model.goToTocEntry(model.tocEntries[0])
        try await pump(scene.hosting, seconds: 0.3)
        #expect(model.currentTocEntry?.id == "gen-0")
        #expect(model.currentPageIndex == 0)
    }

    @Test("real composition: ← on the selected entry (collapseSelectedTocEntry) removes the child rows from the window, → (expandSelectedTocEntry) puts them back; on a leaf ← goes up to the parent")
    func realContentsCollapseAndExpandSelectedEntry() async throws {
        let model = try makeModel()
        defer { cleanup(model) }
        model.sidebarTab = .indice
        let scene = try await hostThreePane(model)
        defer { closeTestWindow(scene.window) }
        try #require(sidebarRowCount(scene.hosting) == 4, Comment(rawValue: viewTreeSummary(scene.hosting)))

        // What `.onKeyPress(.leftArrow)` calls with "Alpha chapter" selected.
        var selected: String? = model.collapseSelectedTocEntry(id: "gen-0")
        try await pump(scene.hosting, seconds: 0.3)
        #expect(selected == "gen-0")
        #expect(model.collapsedTocEntryIds == ["gen-0"])
        #expect(sidebarRowCount(scene.hosting) == 3, "the child row (Beta) must disappear from the window")

        selected = model.expandSelectedTocEntry(id: "gen-0")
        try await pump(scene.hosting, seconds: 0.3)
        #expect(selected == "gen-0")
        #expect(model.collapsedTocEntryIds.isEmpty)
        #expect(sidebarRowCount(scene.hosting) == 4)

        // On a leaf (Delta, T2 under Gamma) ← moves the selection to the parent.
        #expect(model.collapseSelectedTocEntry(id: "gen-3") == "gen-2")
        // → on an expanded parent goes down to the first child.
        #expect(model.expandSelectedTocEntry(id: "gen-2") == "gen-3")
        #expect(sidebarRowCount(scene.hosting) == 4)
    }

    @Test("real composition: 'Show Only T1' and 'Expand All' change the mounted rows; the current entry inside a collapsed chapter highlights the ancestor")
    func realContentsShowOnlyT1AndAncestorHighlight() async throws {
        let model = try makeModel()
        defer { cleanup(model) }
        model.sidebarTab = .indice
        let scene = try await hostThreePane(model)
        defer { closeTestWindow(scene.window) }
        try #require(sidebarRowCount(scene.hosting) == 4)

        model.showOnlyTopLevelTocEntries()
        try await pump(scene.hosting, seconds: 0.3)
        #expect(sidebarRowCount(scene.hosting) == 2, "only the two T1s must stay mounted")
        // Reading position inside "Delta section" (T2 collapsed under Gamma): Gamma highlighted.
        model.pinnedTocEntryID = "gen-3"
        #expect(model.currentTocEntry?.id == "gen-2")

        model.expandAllTocEntries()
        try await pump(scene.hosting, seconds: 0.3)
        #expect(sidebarRowCount(scene.hosting) == 4)
        #expect(model.currentTocEntry?.id == "gen-3")
    }

    @Test("real composition: ⌘⇧1 (toggleSidebar) removes and restores the sidebar with the contents as it was")
    func realSidebarToggleRemovesAndRestoresTheSidebar() async throws {
        let model = try makeModel()
        defer { cleanup(model) }
        model.sidebarTab = .indice
        let scene = try await hostThreePane(model)
        defer { closeTestWindow(scene.window) }
        try #require(sidebarTabPicker(scene.hosting) != nil)
        try #require(sidebarRowCount(scene.hosting) == 4)

        model.toggleSidebar()
        try await pump(scene.hosting, seconds: 0.5)
        #expect(!model.sidebarVisible)
        #expect(sidebarTabPicker(scene.hosting) == nil, "the sidebar is still in the window after ⌘⇧1: \(viewTreeSummary(scene.hosting))")
        #expect(sidebarRowCount(scene.hosting) == 0)

        model.toggleSidebar()
        try await pump(scene.hosting, seconds: 0.5)
        #expect(sidebarTabPicker(scene.hosting) != nil)
        #expect(sidebarRowCount(scene.hosting) == 4, "the contents must come back as they were")
    }

    @Test("real Contents tab: spinner during regeneration with the list still mounted; empty state with no rows and the honest message")
    func realContentsTabShowsRegenerationSpinnerAndHonestEmptyState() async throws {
        let model = try makeModel()
        defer { cleanup(model) }
        model.sidebarTab = .indice
        model.tocGenerationState = .generating
        let scene = try await hostSidebar(model)
        defer { closeTestWindow(scene.window) }
        let spinners = allViews(scene.hosting).filter { className($0).contains("ProgressIndicator") }
        #expect(!spinners.isEmpty, "no sign of life during 'Regenerate contents': \(viewTreeSummary(scene.hosting))")
        #expect(sidebarRowCount(scene.hosting) == 4, "the list stays mounted while regenerating")

        model.tocGenerationState = .idle
        try await pump(scene.hosting, seconds: 0.3)
        #expect(allViews(scene.hosting).filter { className($0).contains("ProgressIndicator") }.isEmpty, "the spinner must disappear when generation ends")

        model.tocEntries = []
        model.structure = DocumentStructure(fingerprint: "fp", pageCount: 3, headings: [], tocCandidates: [], exhibits: [], blocks: [], textlessPages: false, removedHeaderFooterLines: [:], paragraphs: [])
        try await pump(scene.hosting, seconds: 0.3)
        #expect(sidebarRowCount(scene.hosting) == 0, "with an empty list no row must stay mounted")
        // SwiftUI text is not readable from the AppKit hierarchy: the choice
        // of message is a pure function of the same view.
        #expect(ChaptersSidebar.emptyStateHint(structure: model.structure) == "No headings found; select a title and use T1–T4")
        #expect(ChaptersSidebar.emptyStateHint(structure: nil) == "will be generated")
        let withCandidates = DocumentStructure(fingerprint: "fp", pageCount: 3, headings: [], tocCandidates: [TocCandidate(title: "Intro", page: 1, levelHint: 1, source: .heading)], exhibits: [], blocks: [], textlessPages: false, removedHeaderFooterLines: [:], paragraphs: [])
        #expect(ChaptersSidebar.emptyStateHint(structure: withCandidates) == "will be generated")
    }
}
}
