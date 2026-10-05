import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// Geometry model of the lazy panel: paddings consistent with the sum of the
/// heights, estimates replaced by measurements, a window with hysteresis and
/// stepwise growth, absorption of differences above the visible part, and
/// frames for the linked scrolling for ALL rows.
@MainActor
@Suite("RewritePanelGeometry (pure model)")
struct RewritePanelGeometryTests {
    private func paragraphCard(_ chars: Int) -> RewriteRowShape {
        .card(items: [RewriteRowShape.ItemShape(kind: .paragraph, chars: chars)])
    }

    /// 22 rows: a heading, 20 paragraph cards (~190 pt estimated each at
    /// 338 pt), a placeholder.
    private func makeGeometry(width: CGFloat = 338, viewport: (top: CGFloat, height: CGFloat)? = (0, 600)) -> (RewritePanelGeometry, [RewriteRowSpec]) {
        let geometry = RewritePanelGeometry()
        var specs: [RewriteRowSpec] = [RewriteRowSpec(id: "h-0-0", shape: .heading(level: 1))]
        for i in 0 ..< 20 { specs.append(RewriteRowSpec(id: "b-b\(i)", shape: paragraphCard(400))) }
        specs.append(RewriteRowSpec(id: "b-b20", shape: .placeholder))
        geometry.updateFrame(originY: 40, width: width)
        if let viewport { geometry.updateViewport(top: viewport.top, height: viewport.height) }
        geometry.commit(specs)
        return (geometry, specs)
    }

    private func checkPlanConsistency(_ geometry: RewritePanelGeometry, _ specs: [RewriteRowSpec]) {
        let plan = geometry.plan(for: specs)
        var realized: CGFloat = 0
        for i in plan.range {
            realized += geometry.height(of: specs[i].id) ?? 0
            if i < specs.count - 1 { realized += RewritePanelGeometry.rowSpacing }
        }
        // The bottom padding includes the "past the end" tail
        // (`scrollPastEndTail`), so the last card can rise to the reading
        // line; the rest must add up exactly to the total height.
        let tail = RewritePanelGeometry.scrollPastEndTail(viewportHeight: geometry.viewportHeight)
        let sum = plan.topPadding + realized + plan.bottomPadding - tail
        #expect(abs(sum - geometry.totalHeight) < 0.01, "paddings + realized rows (\(sum)) ≠ total height (\(geometry.totalHeight))")
    }

    @Test("the plan immediately covers only the visible rows and the paddings add up to the total height")
    func planCoversVisibleRowsAndPaddingsAreConsistent() {
        let (geometry, specs) = makeGeometry()
        let plan = geometry.plan(for: specs)
        #expect(plan.range.lowerBound == 0)
        #expect(plan.range.upperBound < specs.count, "20 cards do not all fit in 600 pt: the initial window must be partial")
        #expect(plan.topPadding == 0)
        #expect(plan.bottomPadding > 0)
        checkPlanConsistency(geometry, specs)
        #expect(geometry.height(of: "b-b20") == RewriteViewModel.placeholderMinHeight, "SPEC §5.6: a placeholder is 44 pt")
        #expect((geometry.height(of: "b-b0") ?? 0) > 100, "a 400-character paragraph at 338 pt takes up many lines")
    }

    @Test("the window grows stepwise up to the reserve, then stops")
    func windowGrowsStepwise() {
        let (geometry, specs) = makeGeometry()
        let initial = geometry.plan(for: specs).range
        geometry.growStep()
        let afterOne = geometry.plan(for: specs).range
        #expect(afterOne.count == initial.count + 1, "one step = one more row")
        for _ in 0 ..< 40 { geometry.growStep() }
        let settled = geometry.plan(for: specs).range
        #expect(settled.count > afterOne.count)
        #expect(settled.upperBound < specs.count, "the reserve (margin + reserve) does not reach the bottom of 22 rows")
        let again = settled
        geometry.growStep()
        #expect(geometry.plan(for: specs).range == again, "once the reserve is reached it no longer grows")
        checkPlanConsistency(geometry, specs)
    }

    @Test("a measurement replaces the estimate and updates the paddings and the frames of all rows")
    func measurementReplacesEstimate() {
        let (geometry, specs) = makeGeometry()
        let revisionBefore = geometry.revision
        let framesBefore = geometry.rowFrames()
        #expect(framesBefore.count == specs.count, "one frame for EVERY row, realized or not (SPEC §5.8)")
        #expect(framesBefore["h-0-0"]?.minY == 40, "the stack origin (40) is included in the frames")
        geometry.report(id: "b-b0", size: CGSize(width: 338, height: 333))
        #expect(geometry.height(of: "b-b0") == 333)
        #expect(geometry.isMeasured("b-b0"))
        #expect(!geometry.isMeasured("b-b1"))
        // The plan carries the measurement to `RewriteRowsLayout` (which thus no
        // longer queries the row): the panel must be woken once.
        #expect(geometry.revision > revisionBefore)
        let frames = geometry.rowFrames()
        #expect(frames["b-b0"]?.height == 333)
        let start1 = frames["b-b1"]!.minY
        #expect(abs(start1 - (40 + framesBefore["b-b0"]!.minY - 40 + 333 + RewritePanelGeometry.rowSpacing)) < 0.01)
        // Monotonic order guaranteed by construction.
        let sorted = specs.map { frames[$0.id]!.minY }
        #expect(sorted == sorted.sorted())
        checkPlanConsistency(geometry, specs)
    }

    @Test("hysteresis: a small scroll does not change the window, a large one does")
    func windowHysteresis() {
        let (geometry, specs) = makeGeometry()
        for _ in 0 ..< 40 { geometry.growStep() }
        let settled = geometry.plan(for: specs).range
        let revision = geometry.revision
        geometry.updateViewport(top: 40, height: 600)
        #expect(geometry.plan(for: specs).range == settled)
        #expect(geometry.revision == revision, "no panel wake-up for 40 pt")
        geometry.updateViewport(top: geometry.totalHeight - 600, height: 600)
        let atBottom = geometry.plan(for: specs).range
        #expect(atBottom != settled)
        #expect(atBottom.upperBound == specs.count, "at the bottom the last row is visible and therefore realized")
        checkPlanConsistency(geometry, specs)
    }

    @Test("measuring a row above the visible part: the difference is absorbed by the estimates higher up, and the visible row does not move")
    func measurementAboveViewportIsAbsorbed() {
        let (geometry, specs) = makeGeometry(viewport: nil)
        // Move to the bottom (rows 8-11 visible): estimates remain above.
        geometry.updateViewport(top: geometry.totalHeight - 600, height: 600)
        let visibleFirst = geometry.plan(for: specs).range.lowerBound
        #expect(visibleFirst > 2)
        let visibleID = specs[visibleFirst].id
        let startBefore = geometry.rowFrames()[visibleID]!.minY
        let totalBefore = geometry.totalHeight
        // A growth step upward brings in the row above: once realized, it is
        // measured taller than its estimate.
        for _ in 0 ..< 6 { geometry.growStep() }
        let range = geometry.plan(for: specs).range
        #expect(range.lowerBound < visibleFirst, "growth realized at least one row above the visible part")
        let aboveID = specs[range.lowerBound].id
        let estimated = geometry.height(of: aboveID)!
        geometry.report(id: aboveID, size: CGSize(width: 338, height: estimated + 80))
        #expect(geometry.height(of: aboveID) == estimated + 80)
        #expect(abs(geometry.rowFrames()[visibleID]!.minY - startBefore) < 0.01, "the visible row stays where it was")
        #expect(abs(geometry.totalHeight - totalBefore) < 0.01, "the 80 pt came out of the estimates higher up")
        let aboveAbove = specs[range.lowerBound - 1].id
        #expect((geometry.height(of: aboveAbove) ?? 0) < estimated, "the estimate immediately above shrank")
        checkPlanConsistency(geometry, specs)
    }

    @Test("a pinned row (being edited) stays realized even outside the window")
    func pinnedRowStaysRealized() {
        let (geometry, specs) = makeGeometry()
        geometry.setPinned("b-b15", true)
        #expect(geometry.plan(for: specs).range.contains(16), "b-b15 is index 16 of the sequence (heading + cards)")
        geometry.setPinned("b-b15", false)
        for _ in 0 ..< 40 { geometry.growStep() }
        #expect(!geometry.plan(for: specs).range.contains(16))
    }

    @Test("a shape change (text changed) discards the measurement; a width change sets it aside and finds it again")
    func shapeAndWidthInvalidation() {
        let (geometry, specs) = makeGeometry()
        geometry.report(id: "b-b0", size: CGSize(width: 338, height: 333))
        var changed = specs
        changed[1] = RewriteRowSpec(id: "b-b0", shape: paragraphCard(1400))
        geometry.commit(changed)
        #expect(!geometry.isMeasured("b-b0"))
        #expect((geometry.height(of: "b-b0") ?? 0) > 333, "new estimate for a doubled text")
        geometry.commit(specs)
        #expect(geometry.isMeasured("b-b0"), "original shape restored, the measurement is still valid")
        geometry.updateFrame(originY: 40, width: 500)
        #expect(!geometry.isMeasured("b-b0"), "different width: the measurement does not apply")
        geometry.updateFrame(originY: 40, width: 338)
        #expect(geometry.isMeasured("b-b0"), "previous width: the measurement is still there")
    }

    @Test("the provisional plan for rows not yet committed matches the one after the commit")
    func provisionalPlanMatchesCommittedPlan() {
        let geometry = RewritePanelGeometry()
        geometry.updateFrame(originY: 0, width: 338)
        geometry.updateViewport(top: 0, height: 600)
        var specs: [RewriteRowSpec] = []
        for i in 0 ..< 8 { specs.append(RewriteRowSpec(id: "b-b\(i)", shape: paragraphCard(300))) }
        let provisional = geometry.plan(for: specs)
        geometry.commit(specs)
        #expect(geometry.plan(for: specs) == provisional)
    }
}
