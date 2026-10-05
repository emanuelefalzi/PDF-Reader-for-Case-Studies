import Foundation
import Testing
@testable import LelePdf

/// `DocumentModel` contents collapsing: disclosure triangle (collapse/expand
/// one entry), ⌥-click (subtree), "Show only top-level"/"Expand all",
/// left/right arrows as in Finder, highlighting of the visible ancestor,
/// per-document persistence.
@MainActor
@Suite("DocumentModel · collapsible contents", .serialized)
struct DocumentModelTocCollapseTests {
    /// Same scheme as `SidebarIndexLegendRenderTests.makeModel`: a minimal
    /// synthetic PDF, a hand-built level-1/2/3 tree (no real PDFView needed,
    /// these commands work only on `tocEntries`/the Store).
    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova.", fileName: "toc-collapse-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "toc-collapse-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
        model.tocSource = .generated
        model.tocEntries = [
            TocEntry(id: "t1a", title: "Capitolo 1", level: 1, page: 0),
            TocEntry(id: "t2a", title: "1.1 Sezione", level: 2, page: 0),
            TocEntry(id: "t3a", title: "1.1.1 Sotto-sezione", level: 3, page: 0),
            TocEntry(id: "t2b", title: "1.2 Sezione", level: 2, page: 1),
            TocEntry(id: "t1b", title: "Capitolo 2", level: 1, page: 2),
        ]
        return model
    }


    @Test("disclosure triangle: collapses ONLY the entry, not the siblings/the uncle")
    func toggleSingleEntry() throws {
        let model = try makeModel()
        model.toggleTocEntryCollapsed(id: "t2a")
        #expect(model.collapsedTocEntryIds == ["t2a"])
        model.toggleTocEntryCollapsed(id: "t2a")
        #expect(model.collapsedTocEntryIds.isEmpty)
    }

    @Test("⌥-click: collapses the entry AND every descendant that has children of its own")
    func toggleSubtree() throws {
        let model = try makeModel()
        model.toggleTocSubtreeCollapsed(id: "t1a")
        // t1a has children (t2a, t3a); t2a in turn has children (t3a); t3a
        // is a leaf, so t1a and t2a enter the set, not t3a (a leaf has no
        // meaningful collapsed state of its own).
        #expect(model.collapsedTocEntryIds == ["t1a", "t2a"])

        model.toggleTocSubtreeCollapsed(id: "t1a")
        #expect(model.collapsedTocEntryIds.isEmpty)
    }

    @Test("Show only top-level entries: collapses the chapters, Expand all reopens them")
    func showOnlyTopLevelThenExpandAll() throws {
        let model = try makeModel()
        model.showOnlyTopLevelTocEntries()
        #expect(model.collapsedTocEntryIds == ["t1a"]) // t1b is a leaf, it has no children

        model.expandAllTocEntries()
        #expect(model.collapsedTocEntryIds.isEmpty)
    }

    @Test("left arrow on an expanded entry with children: collapses it, the selection stays there")
    func leftArrowCollapsesExpandedEntry() throws {
        let model = try makeModel()
        let next = model.collapseSelectedTocEntry(id: "t1a")
        #expect(next == "t1a")
        #expect(model.collapsedTocEntryIds.contains("t1a"))
    }

    @Test("left arrow on a leaf: moves up to the parent, as in Finder")
    func leftArrowOnLeafMovesToParent() throws {
        let model = try makeModel()
        let next = model.collapseSelectedTocEntry(id: "t3a")
        #expect(next == "t2a")
        #expect(model.collapsedTocEntryIds.isEmpty) // no collapse, only a selection change
    }

    @Test("right arrow on a collapsed entry: expands it, the selection stays there")
    func rightArrowExpandsCollapsedEntry() throws {
        let model = try makeModel()
        model.toggleTocEntryCollapsed(id: "t1a")
        let next = model.expandSelectedTocEntry(id: "t1a")
        #expect(next == "t1a")
        #expect(!model.collapsedTocEntryIds.contains("t1a"))
    }

    @Test("right arrow on an already expanded entry: moves down to the first child, as in Finder")
    func rightArrowOnExpandedEntryMovesToFirstChild() throws {
        let model = try makeModel()
        let next = model.expandSelectedTocEntry(id: "t1a")
        #expect(next == "t2a")
    }

    @Test("the reading position inside a collapsed entry highlights its visible ancestor")
    func currentEntryFallsBackToVisibleAncestorWhenCollapsed() throws {
        let model = try makeModel()
        model.pinnedTocEntryID = "t3a" // as after a direct click on the entry
        model.toggleTocEntryCollapsed(id: "t2a") // hides t3a

        #expect(model.currentTocEntry?.id == "t2a", "t3a is hidden: the visible parent t2a must win")
    }

    @Test("without collapsed entries the behavior stays as before")
    func currentEntryUnaffectedWithoutCollapse() throws {
        let model = try makeModel()
        model.pinnedTocEntryID = "t3a"
        #expect(model.currentTocEntry?.id == "t3a")
    }

    // Real persistence (documento.json, round trip with a real DocumentStore)
    // is verified in `DocumentStoreTocCollapseTests`: a synthetic
    // `DocumentModel` like this one (no real PDF, no `PipelineRunner` ever
    // started; only `PDFKitView.makeNSView` starts it in the real app) never
    // gets a real `storeFingerprint` on its own, the same known cause as for
    // `attachStructureToStore` (SPEC §7: the fingerprint comes from the TEXT
    // extracted by the pipeline, not from the file's byte hash alone, for a
    // document NEVER seen before).
}
