import Foundation

/// Collapsible and expandable contents: `DocumentModel` commands for
/// `ChaptersSidebar` (disclosure triangle, ⌥-click, arrows) and the "Show
/// Only T1"/"Expand All" menu. Kept in a file separate from
/// `DocumentModel.swift`/`DocumentModelManualToc.swift` to keep files
/// short.
@MainActor
extension DocumentModel {
    /// Ids of the collapsed entries (hidden children), read directly from
    /// `documentRecord`, the same pattern as `colorTheme` (a computed
    /// property, not a second published state to keep in sync by hand):
    /// `nil`/absent in a `documento.json` written before this feature
    /// equals "no collapsed entries".
    var collapsedTocEntryIds: Set<String> {
        if let pendingCollapsedTocEntryIds { return pendingCollapsedTocEntryIds }
        return Set(documentRecord?.collapsedTocEntryIds ?? [])
    }

    /// Indentation depth of the VISUAL tree, the same basis as
    /// `ChaptersSidebar`/`ManualToc.indentDepths`, computed here once and
    /// reused by all the commands below (never the raw `level` 1-4: an
    /// orphan T3 with no T2 above it follows the same indentation the user
    /// sees).
    private var tocDepths: [Int] {
        ManualToc.indentDepths(levels: tocEntries.map(\.level))
    }

    /// Disclosure triangle (click): collapses/expands ONLY this entry.
    func toggleTocEntryCollapsed(id: String) {
        var ids = collapsedTocEntryIds
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        setCollapsedTocEntryIds(ids)
    }

    /// ⌥-click on the triangle ("expands/collapses the whole subtree"):
    /// the same new state (collapse if it was not collapsed, otherwise
    /// expand) applied to THIS entry and to each of its descendants that
    /// has children in turn, so re-expanding the parent later does not reveal
    /// an intermediate level that stayed collapsed on its own.
    func toggleTocSubtreeCollapsed(id: String) {
        guard let index = tocEntries.firstIndex(where: { $0.id == id }) else { return }
        let depths = tocDepths
        let subtreeIds = TocCollapse.subtreeIds(of: index, ids: tocEntries.map(\.id), depths: depths)
        var ids = collapsedTocEntryIds
        if ids.contains(id) {
            ids.subtract(subtreeIds)
        } else {
            ids.formUnion(subtreeIds)
        }
        setCollapsedTocEntryIds(ids)
    }

    /// "Show Only T1" menu.
    func showOnlyTopLevelTocEntries() {
        setCollapsedTocEntryIds(TocCollapse.topLevelCollapsedIds(ids: tocEntries.map(\.id), depths: tocDepths))
    }

    /// "Expand All" menu.
    func expandAllTocEntries() {
        setCollapsedTocEntryIds([])
    }

    /// Left/right arrows on the selected entry, as in the Finder ("left/right
    /// arrows collapse/expand the selected entry"): if the entry has children
    /// and is expanded, left collapses it; if it has no children (or is
    /// already collapsed), left moves the selection to the parent. Right does
    /// the symmetric thing (expands, or descends to the first child if
    /// already expanded). Returns the id to select next (never `nil` if `id`
    /// exists in the contents: at worst it stays the same entry).
    func collapseSelectedTocEntry(id: String) -> String? {
        guard let index = tocEntries.firstIndex(where: { $0.id == id }) else { return id }
        let depths = tocDepths
        let hasChildren = TocCollapse.hasChildren(depths: depths)[index]
        if hasChildren, !collapsedTocEntryIds.contains(id) {
            toggleTocEntryCollapsed(id: id)
            return id
        }
        // Leaf or already collapsed: moves the selection to the parent (the
        // nearest previous entry with a smaller depth), as in the Finder.
        let myDepth = depths[index]
        var cursor = index - 1
        while cursor >= 0 {
            if depths[cursor] < myDepth { return tocEntries[cursor].id }
            cursor -= 1
        }
        return id
    }

    func expandSelectedTocEntry(id: String) -> String? {
        guard let index = tocEntries.firstIndex(where: { $0.id == id }) else { return id }
        let depths = tocDepths
        let hasChildren = TocCollapse.hasChildren(depths: depths)[index]
        guard hasChildren else { return id }
        if collapsedTocEntryIds.contains(id) {
            toggleTocEntryCollapsed(id: id)
            return id
        }
        // Already expanded: descends to the first visible child, as in the Finder.
        if index + 1 < tocEntries.count, depths[index + 1] > depths[index] {
            return tocEntries[index + 1].id
        }
        return id
    }

    /// Not `private`: also called by
    /// `DocumentModelManualToc.swift`/`DocumentModelManualTocUndo.swift`
    /// to carry the collapsed state over to an entry's new ids.
    func setCollapsedTocEntryIds(_ ids: Set<String>) {
        guard let storeFingerprint else {
            pendingCollapsedTocEntryIds = ids
            return
        }
        pendingCollapsedTocEntryIds = nil
        documentRecord?.collapsedTocEntryIds = ids.sorted()
        Task { await AppStore.shared.updateCollapsedTocEntryIds(fingerprint: storeFingerprint, ids: ids) }
    }
}
