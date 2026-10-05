import AppKit

/// Built window, stepwise growth, absorption of measured-minus-estimated
/// differences, scroll compensation, and the rectangles for linked scrolling.
/// Separate file from `RewritePanelGeometry.swift` only to keep files
/// under ~12 KB.
@MainActor
extension RewritePanelGeometry {
    /// Rows that intersect the visible part widened on each side (0 = only
    /// the visible ones, 1 = the "needed" margin, 2 = margin plus reserve),
    /// plus pinned rows. With a 1046 pt window: margin 350, reserve 260, so
    /// about two screens' worth of rows are built in total.
    func neededRange(starts: [CGFloat], heights: [CGFloat], slack: CGFloat, ids: [String]) -> Range<Int> {
        guard !heights.isEmpty else { return 0 ..< 0 }
        let visibleHeight = viewportHeight > 0 ? viewportHeight : Self.defaultViewportHeight
        var margin: CGFloat = 0
        if slack >= 1 { margin += max(Self.minMargin, visibleHeight / 3) }
        if slack >= 2 { margin += max(Self.minReserve, visibleHeight / 4) }
        let lowY = viewportTop - margin
        let highY = viewportTop + visibleHeight + margin
        var lower = heights.count
        var upper = 0
        for i in heights.indices where starts[i] + heights[i] > lowY && starts[i] < highY {
            lower = min(lower, i)
            upper = max(upper, i + 1)
        }
        if lower >= upper {
            // No row in range (past the bottom): take the last one.
            lower = heights.count - 1
            upper = heights.count
        }
        for (i, id) in ids.enumerated() where pinned.contains(id) {
            lower = min(lower, i)
            upper = max(upper, i + 1)
        }
        return lower ..< upper
    }

    /// Updates the built window. Visible rows enter immediately; margin rows
    /// (up to the window with reserve) enter one per run-loop turn
    /// (`growStep`); rows that fall out of the reserve are released at once
    /// (free). With `force == false` it does nothing while the current window
    /// still covers the whole "needed" margin (hysteresis: no rebuilds on
    /// every pixel of scrolling).
    func updateWindow(force: Bool) {
        let ids = rows.map(\.id)
        guard !rows.isEmpty else {
            realizedRange = 0 ..< 0
            return
        }
        let needed = neededRange(starts: starts, heights: heights, slack: 1, ids: ids)
        let current = realizedRange.clamped(to: 0 ..< rows.count)
        if !force, current == realizedRange, current.lowerBound <= needed.lowerBound, needed.upperBound <= current.upperBound {
            return
        }
        let reserve = neededRange(starts: starts, heights: heights, slack: 2, ids: ids)
        let visible = neededRange(starts: starts, heights: heights, slack: 0, ids: ids)
        let kept = current.clamped(to: reserve)
        let next = kept.isEmpty ? visible : min(kept.lowerBound, visible.lowerBound) ..< max(kept.upperBound, visible.upperBound)
        realizedRange = next
        if next != reserve { scheduleGrowStep() }
    }

    /// One growth step toward the window with reserve: downward first (the
    /// reading direction), then upward. It recomputes the reserve each time,
    /// since the visible part may have changed in the meantime.
    func growStep() {
        guard !rows.isEmpty else { return }
        let reserve = neededRange(starts: starts, heights: heights, slack: 2, ids: rows.map(\.id))
        var range = realizedRange.clamped(to: 0 ..< rows.count)
        if range.isEmpty {
            updateWindow(force: true)
            refreshPlan()
            return
        }
        if range.upperBound < reserve.upperBound {
            range = range.lowerBound ..< range.upperBound + 1
        } else if range.lowerBound > reserve.lowerBound {
            range = range.lowerBound - 1 ..< range.upperBound
        } else {
            return
        }
        realizedRange = range
        refreshPlan()
        if range != reserve { scheduleGrowStep() }
    }

    /// Not `DispatchQueue.main.async`: the main queue drains all blocks
    /// queued in the same turn, so every step would land in the same frame.
    /// A minimal delay separates them, one per turn.
    func scheduleGrowStep() {
        guard !growStepScheduled else { return }
        growStepScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
            guard let self else { return }
            self.growStepScheduled = false
            self.growStep()
        }
    }

    /// Distributes `delta` (measured minus estimated height of a row above
    /// the visible part) over the estimates of the unbuilt rows further up,
    /// starting from the nearest; returns whatever could not be absorbed.
    func absorbAbove(index: Int, delta: CGFloat) -> CGFloat {
        var remaining = delta
        let limit = min(index, realizedRange.lowerBound)
        for j in (0 ..< max(0, limit)).reversed() where measuredHeight(index: j) == nil && remaining != 0 {
            let current = estimates[j]
            let next = max(Self.minEstimate, current - remaining)
            remaining -= current - next
            absorbedPoints += abs(current - next)
            estimates[j] = next
        }
        return remaining
    }

    /// Scrolls by the equal and opposite amount of the part of `delta` that
    /// was not absorbed, under the coordinator's guard (SPEC §5.8 "a
    /// programmatic scroll does not retrigger synchronization").
    func compensateScroll(by delta: CGFloat) {
        guard let model, let scrollView = model.rewriteScrollView, let (top, _) = DocumentSpace.visibleTopDown(scrollView) else { return }
        let wanted = top + delta
        var applied: CGFloat = top
        compensationCount += 1
        model.syncCoordinator.performGuardedNavigation {
            applied = DocumentSpace.scroll(scrollView, topDownTop: wanted)
        }
        // Clamped because the content height has not grown yet (we are
        // inside layout): retry on the next turn.
        if abs(applied - wanted) >= 0.5 {
            let rest = wanted - applied
            DispatchQueue.main.async { [weak self] in self?.compensateScroll(by: rest) }
        }
    }

    // MARK: - Rectangles for linked scrolling (SPEC §5.8)

    /// One turn per pass: several measurements in the same layout produce a
    /// single rebuild of the alignment.
    func schedulePublish() {
        guard !framesPublishScheduled else { return }
        framesPublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.framesPublishScheduled = false
            self.publishFrames()
        }
    }

    func rowFrames() -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        frames.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() where i < starts.count {
            frames[row.id] = CGRect(x: 0, y: originY + starts[i], width: width, height: heights[i])
        }
        return frames
    }
}
