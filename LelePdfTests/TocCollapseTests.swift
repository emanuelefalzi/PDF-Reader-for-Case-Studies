import Foundation
import Testing
@testable import LelePdf

/// F11: `TocCollapse`: who has children, which indices are visible given a
/// set of collapsed entries, the nearest visible ancestor, "Show Only T1",
/// the subtree of an ⌥-click.
@Suite("TocCollapse")
struct TocCollapseTests {
    // T1(0) -> T2(1) -> T3(2) -> T2(1, sibling) -> T1(0, sibling, foglia)
    private let depths = [0, 1, 2, 1, 0]
    private let ids = ["t1a", "t2a", "t3a", "t2b", "t1b"]

    @Test("hasChildren: true only if the entry IMMEDIATELY after has greater depth")
    func hasChildren() {
        let result = TocCollapse.hasChildren(depths: depths)
        #expect(result == [true, true, false, false, false])
    }

    @Test("descendantIndices: the whole contiguous run with greater depth")
    func descendantIndices() {
        #expect(TocCollapse.descendantIndices(of: 0, depths: depths) == 1 ..< 4) // t1a: t2a, t3a, t2b (not t1b)
        #expect(TocCollapse.descendantIndices(of: 1, depths: depths) == 2 ..< 3) // t2a: only t3a
        #expect(TocCollapse.descendantIndices(of: 4, depths: depths) == 5 ..< 5) // t1b: leaf, none
    }

    @Test("visibleIndices: collapsing t2a hides t3a, not t2b/t1b")
    func visibleIndicesHidesOnlyOwnSubtree() {
        let visible = TocCollapse.visibleIndices(ids: ids, depths: depths, collapsed: ["t2a"])
        #expect(visible == [true, true, false, true, true])
    }

    @Test("visibleIndices: collapsing the parent hides the whole subtree, even if a child is also in the set")
    func visibleIndicesNestedCollapse() {
        let visible = TocCollapse.visibleIndices(ids: ids, depths: depths, collapsed: ["t1a", "t2a"])
        #expect(visible == [true, false, false, false, true])
    }

    @Test("visibleIndices: no collapsed entries, everything visible")
    func visibleIndicesEmptyCollapsedSet() {
        #expect(TocCollapse.visibleIndices(ids: ids, depths: depths, collapsed: []) == [true, true, true, true, true])
    }

    @Test("nearestVisibleAncestor: an already visible entry returns itself")
    func nearestVisibleAncestorAlreadyVisible() {
        let visible = TocCollapse.visibleIndices(ids: ids, depths: depths, collapsed: [])
        #expect(TocCollapse.nearestVisibleAncestor(of: 2, depths: depths, visible: visible) == 2)
    }

    @Test("nearestVisibleAncestor: a hidden entry climbs to the nearest visible parent")
    func nearestVisibleAncestorClimbsToParent() {
        let visible = TocCollapse.visibleIndices(ids: ids, depths: depths, collapsed: ["t2a"])
        // t3a (index 2) is hidden: the nearest visible parent is t2a (index 1).
        #expect(TocCollapse.nearestVisibleAncestor(of: 2, depths: depths, visible: visible) == 1)
    }

    @Test("nearestVisibleAncestor: two collapsed levels, climbs up to the T1")
    func nearestVisibleAncestorClimbsTwoLevels() {
        let visible = TocCollapse.visibleIndices(ids: ids, depths: depths, collapsed: ["t1a"])
        #expect(TocCollapse.nearestVisibleAncestor(of: 2, depths: depths, visible: visible) == 0)
    }

    @Test("topLevelCollapsedIds (\"Show Only T1\"): only entries at depth 0 THAT HAVE children")
    func topLevelCollapsedIds() {
        let result = TocCollapse.topLevelCollapsedIds(ids: ids, depths: depths)
        #expect(result == ["t1a"]) // t1b is at depth 0 but is a leaf (hasChildren == false)
    }

    @Test("subtreeIds (⌥-click): the entry and every descendant that ALSO has children, not the leaves")
    func subtreeIdsOnlyIncludesEntriesWithChildren() {
        let result = TocCollapse.subtreeIds(of: 0, ids: ids, depths: depths)
        // t1a has children, t2a has children (t3a); t3a and t2b/t1b are leaves or outside the subtree.
        #expect(Set(result) == ["t1a", "t2a"])
    }

    @Test("subtreeIds on a leaf: only itself")
    func subtreeIdsOnLeafIsJustItself() {
        #expect(TocCollapse.subtreeIds(of: 2, ids: ids, depths: depths) == ["t3a"])
    }
}
