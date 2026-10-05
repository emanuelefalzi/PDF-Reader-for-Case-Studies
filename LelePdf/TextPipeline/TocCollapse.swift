import Foundation

/// Collapsible and expandable contents: pure functions over the same
/// `depths` already computed by `ManualToc.indentDepths` (the VISUAL
/// indentation of the tree, not the saved `level` 1-4; an orphan T3 with no
/// T2 above attaches to the T1, M7-2: "has children"/"is a descendant of"
/// therefore follow the same hierarchy the user sees, not the printed T
/// number). No dependency on SwiftUI/AppKit, testable on its own.
enum TocCollapse {
    /// An entry "has children" if the entry RIGHT after it (in the given
    /// order) has a greater depth, i.e. it is the first entry of a subtree
    /// under it. Only entries with children show the disclosure triangle
    /// ("every entry THAT HAS children can be collapsed/expanded").
    static func hasChildren(depths: [Int]) -> [Bool] {
        var result = [Bool](repeating: false, count: depths.count)
        for index in depths.indices where index + 1 < depths.count {
            result[index] = depths[index + 1] > depths[index]
        }
        return result
    }

    /// Range (excluding `index`) of the direct and indirect descendants of
    /// `index`: the following contiguous run with a depth greater than its
    /// own, up to the next entry at its same depth or higher in the tree (or
    /// the end of the array).
    static func descendantIndices(of index: Int, depths: [Int]) -> Range<Int> {
        guard depths.indices.contains(index) else { return index ..< index }
        let baseDepth = depths[index]
        var end = index + 1
        while end < depths.count, depths[end] > baseDepth { end += 1 }
        return (index + 1) ..< end
    }

    /// Which entries are visible given the set of collapsed entries
    /// (`collapsed`, ids): an entry is hidden if ANY ancestor of it (not just
    /// the direct parent) is collapsed. There is no need to follow a whole
    /// stack of ancestors: it is enough to keep the depth of the outermost
    /// hidden ancestor until we return to a depth equal to or lower than its
    /// own (`hiddenBelowDepth`).
    static func visibleIndices(ids: [String], depths: [Int], collapsed: Set<String>) -> [Bool] {
        var visible = [Bool](repeating: true, count: ids.count)
        var hiddenBelowDepth: Int?
        for index in ids.indices {
            let depth = depths[index]
            if let hiddenDepth = hiddenBelowDepth, depth > hiddenDepth {
                visible[index] = false
            } else {
                hiddenBelowDepth = nil
                visible[index] = true
            }
            if visible[index], collapsed.contains(ids[index]) {
                hiddenBelowDepth = depth
            }
        }
        return visible
    }

    /// "The reading point is inside a collapsed entry → its visible ancestor
    /// is highlighted": walks up from the entry found by the geometric
    /// computation (`TocNavigation.currentEntry`) through the array, to the
    /// first VISIBLE entry with a lower or equal depth: that same entry if it
    /// is already visible (the common case, no collapsed ancestor), otherwise
    /// its nearest visible parent.
    static func nearestVisibleAncestor(of index: Int, depths: [Int], visible: [Bool]) -> Int? {
        guard depths.indices.contains(index) else { return nil }
        if visible[index] { return index }
        var cursor = index - 1
        let targetDepth = depths[index]
        var maxAllowedDepth = targetDepth
        while cursor >= 0 {
            if depths[cursor] < maxAllowedDepth {
                if visible[cursor] { return cursor }
                maxAllowedDepth = depths[cursor]
            }
            cursor -= 1
        }
        return nil
    }

    /// "Show only T1s" (View/contextual menu): collapses every entry at depth
    /// 0 (the top of the VISUAL tree, not necessarily `level == 1` in every
    /// edge case; an orphan T2 with no T1 above is also at depth 0 and must be
    /// collapsed to stay consistent with "only the first level remains
    /// visible") that has children.
    static func topLevelCollapsedIds(ids: [String], depths: [Int]) -> Set<String> {
        let children = hasChildren(depths: depths)
        var result: Set<String> = []
        for index in ids.indices where depths[index] == 0 && children[index] {
            result.insert(ids[index])
        }
        return result
    }

    /// ⌥-click on the triangle: the ids of `index` and of ALL its descendants
    /// that in turn have children (the only entries for which "collapsed" has
    /// a meaning), used to collapse or expand a whole subtree together in a
    /// single gesture.
    static func subtreeIds(of index: Int, ids: [String], depths: [Int]) -> [String] {
        guard ids.indices.contains(index) else { return [] }
        let children = hasChildren(depths: depths)
        var result = [ids[index]]
        for i in descendantIndices(of: index, depths: depths) where children[i] {
            result.append(ids[i])
        }
        return result
    }
}
