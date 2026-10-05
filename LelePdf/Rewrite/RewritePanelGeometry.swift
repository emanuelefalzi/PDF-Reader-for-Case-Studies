import AppKit
import Observation

/// A right-hand panel row as seen by the geometry model: a stable id (the
/// same as `RewriteRow`/`AlignmentBuilder`) plus the lightweight shape used
/// to estimate its height and to sign its measurement.
struct RewriteRowSpec: Equatable, Sendable {
    let id: String
    let shape: RewriteRowShape
}

/// Geometry of the lazy right-hand panel. The panel builds ONLY the rows
/// inside a window around the visible part (`plan(for:)`); all the others
/// exist here as a height (measured at the current width if the row has been
/// built at least once, otherwise estimated by `RewriteRowHeightEstimator`).
/// From these heights, using the same running sum, derive:
/// - the two fillers above/below the built window (`Plan`), so the
///   scrollable content always has the height of the whole sequence;
/// - the rectangles of ALL rows for `ScrollSyncCoordinator`/
///   `AlignmentBuilder` (SPEC §5.8): linked scrolling no longer depends on
///   the live frames of each card (`RowFramesPreferenceKey`, which would not
///   exist for rows outside the window in a lazy stack) but on this model.
///   Visible rows are always measured, so what is seen at the reading line
///   is exact; rows never seen are estimated, and the estimate is replaced
///   by the measurement as soon as they enter the window.
///
/// The window grows in steps (`+Window.swift`): rows that intersect the
/// visible part are built immediately, margin rows one per run-loop turn, so
/// a page jump or a scroll tick pays for at most one new card per frame.
///
/// When a row ABOVE the visible part is measured for the first time and the
/// measurement differs from the estimate, the visible content would shift:
/// the difference is first absorbed by the estimates of the not-yet-built
/// rows further up (they are only estimates, so correcting them changes
/// nothing visible) and, only if there are not enough of them, compensated
/// with an equal and opposite programmatic scroll, under the coordinator's
/// guard (no bounce, SPEC §5.8).
@MainActor
@Observable
final class RewritePanelGeometry {
    /// Stack spacing (the same as the `VStack` in `RewritePanel`).
    static let rowSpacing: CGFloat = 10
    /// Used until the scroll view has a size (first layout).
    static let defaultViewportHeight: CGFloat = 1000
    /// Minimum margin, above and below the visible part, within which rows
    /// are built ahead of time (so they are already measured when they
    /// enter).
    static let minMargin: CGFloat = 240
    /// Reserve beyond the margin: rows that have entered stay built until
    /// they leave this area too (hysteresis), so scrolling back and forth a
    /// little rebuilds nothing.
    static let minReserve: CGFloat = 160
    /// An "absorbed" estimate (see above) never drops below this height.
    static let minEstimate: CGFloat = 20
    /// Empty space at the tail of the stack so that even the LAST card can
    /// rise to the reading line (30% from the top, SPEC §5.8). Without it, at
    /// the end of the document the panel stops at its own limit and the last
    /// cards stay below the line (measured: an offset of 110-280 pt on the
    /// last pages of the fully analyzed Merck case). Below the rows there are
    /// already the "Analyze next block" button and the bottom margin
    /// (`DSMetrics.rightPanelBottomMargin`).
    static func scrollPastEndTail(viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight * (1 - ScrollSyncCoordinator.readingLineFraction) - DSMetrics.rightPanelBottomMargin - 60)
    }

    struct Plan: Equatable {
        var range: Range<Int>
        var topPadding: CGFloat
        var bottomPadding: CGFloat
        /// For each row in `range`: the height measured at the current width,
        /// or `nil` if the row still needs measuring (`RewriteRowsLayout`
        /// queries ONLY these).
        var measuredHeights: [CGFloat?]
        /// For each row in `range`: the model height (measurement or
        /// estimate), to answer proposals without a width (the ideal size of
        /// the `NSHostingView`) without querying any row.
        var modelHeights: [CGFloat]
        static let empty = Plan(range: 0 ..< 0, topPadding: 0, bottomPadding: 0, measuredHeights: [], modelHeights: [])
    }

    /// The ONLY property observed by the panel: it changes only when the plan
    /// (built window, fillers) has really changed.
    private(set) var revision = 0

    @ObservationIgnored private(set) var rows: [RewriteRowSpec] = []
    @ObservationIgnored var indexByID: [String: Int] = [:]
    /// Current estimate per row (may have been "absorbed", see above).
    @ObservationIgnored var estimates: [CGFloat] = []
    @ObservationIgnored var heights: [CGFloat] = []
    @ObservationIgnored var starts: [CGFloat] = []
    @ObservationIgnored private(set) var totalHeight: CGFloat = 0
    /// Measured heights: width -> id -> (shape at measurement time, height).
    /// A measurement is valid only for the same width and the same shape
    /// (text changed = shape changed = measurement discarded).
    @ObservationIgnored var measuredByWidth: [CGFloat: [String: (shape: RewriteRowShape, height: CGFloat)]] = [:]
    @ObservationIgnored private(set) var width: CGFloat = 0
    /// Top of the stack in scrollable content space (below the banners and
    /// the "Continue" button: see `RewriteSyncCoordinateSpace`).
    @ObservationIgnored var originY: CGFloat = 0
    @ObservationIgnored private(set) var viewportTop: CGFloat = 0
    @ObservationIgnored private(set) var viewportHeight: CGFloat = 0
    @ObservationIgnored var realizedRange: Range<Int> = 0 ..< 0
    @ObservationIgnored private(set) var currentPlan: Plan = .empty
    /// Rows to keep built even outside the window (a card in "Edit text"
    /// must not lose the edit in progress when scrolled away).
    @ObservationIgnored var pinned: Set<String> = []
    @ObservationIgnored weak var model: DocumentModel?
    @ObservationIgnored var framesPublishScheduled = false
    /// Measurements that arrived for rows not yet committed (the first pass
    /// of `body` uses the provisional plan and rows are measured before
    /// `onChange` delivers the shapes): applied at the next `commit`.
    @ObservationIgnored private var pendingReports: [String: (width: CGFloat, height: CGFloat)] = [:]
    @ObservationIgnored var growStepScheduled = false
    /// Diagnostic counter (tests/benchmark): how many times the rectangles
    /// have been published to the coordinator.
    @ObservationIgnored private(set) var publishedFramesCount = 0
    /// TRUE rectangle (content space, from the view) of each built row, as
    /// SwiftUI placed it: the ground truth for the alignment benchmark,
    /// independent of `starts`/`heights`.
    @ObservationIgnored private(set) var realizedFrames: [String: CGRect] = [:]
    /// Diagnostic counters: compensating scrolls performed and points
    /// absorbed by the estimates (see `+Window.swift`).
    @ObservationIgnored var compensationCount = 0
    @ObservationIgnored var absorbedPoints: CGFloat = 0

    // MARK: - Inputs

    /// Current rows (from the panel's `body`, via `onChange`): order and
    /// shapes. Estimates of rows that stayed the same (same id, same shape)
    /// survive, including absorbed corrections.
    func commit(_ specs: [RewriteRowSpec]) {
        guard specs != rows else { return }
        var kept: [String: (shape: RewriteRowShape, estimate: CGFloat)] = [:]
        for (i, row) in rows.enumerated() where i < estimates.count { kept[row.id] = (row.shape, estimates[i]) }
        rows = specs
        indexByID = Dictionary(specs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        estimates = specs.map { spec in
            if let previous = kept[spec.id], previous.shape == spec.shape { return previous.estimate }
            return RewriteRowHeightEstimator.estimate(spec.shape, width: max(width, 1))
        }
        applyPendingReports()
        relayout(forceWindow: true)
    }

    /// Measurements that arrived before the width or the rows were known (the
    /// rows' `onGeometryChange` actions run before the stack's, and the first
    /// pass precedes `onChange`): they are valid for the current width, the
    /// same one the rows were placed at.
    private func applyPendingReports() {
        guard !pendingReports.isEmpty else { return }
        for (id, entry) in pendingReports {
            guard let index = indexByID[id] else { continue }
            measuredByWidth[entry.width, default: [:]][id] = (rows[index].shape, entry.height)
            pendingReports[id] = nil
        }
    }

    /// Top and width of the stack in content space (measured by the panel
    /// with `onGeometryChange`).
    func updateFrame(originY: CGFloat, width: CGFloat) {
        let roundedWidth = (width * 2).rounded() / 2
        var changed = false
        if roundedWidth != self.width, roundedWidth > 0 {
            self.width = roundedWidth
            estimates = rows.map { RewriteRowHeightEstimator.estimate($0.shape, width: roundedWidth) }
            changed = true
        }
        if originY != self.originY {
            self.originY = originY
            changed = true
        }
        guard changed else { return }
        applyPendingReports()
        relayout(forceWindow: true)
    }

    /// Visible part of the scroll view (top-down space, `DocumentSpace`),
    /// from the `RewriteScrollHost`.
    func updateViewport(top: CGFloat, height: CGFloat) {
        let heightChanged = height != viewportHeight
        viewportTop = top
        viewportHeight = height
        updateWindow(force: heightChanged)
        refreshPlan()
    }

    /// True size of a built row (from the panel, `onGeometryChange`). The
    /// measurement is valid for the ROW's width (equal to the stack's, since
    /// every row fills it), not for `width`, which may still be the previous
    /// one in the same layout turn (the rows' actions run before the stack's).
    /// From the panel (`onGeometryChange` on the row's rectangle): keeps the
    /// true rectangle for diagnostics and passes the size on to
    /// `report(id:size:)`.
    func report(id: String, frame: CGRect) {
        realizedFrames[id] = frame
        report(id: id, size: frame.size)
    }

    func report(id: String, size: CGSize) {
        guard size.height > 0, size.width > 0 else { return }
        let height = (size.height * 2).rounded() / 2
        let rowWidth = (size.width * 2).rounded() / 2
        guard let index = indexByID[id], index < rows.count else {
            pendingReports[id] = (rowWidth, height)
            return
        }
        let shape = rows[index].shape
        if let entry = measuredByWidth[rowWidth]?[id], entry.shape == shape, entry.height == height { return }
        measuredByWidth[rowWidth, default: [:]][id] = (shape, height)
        // Width differs from the stack's current one: the measurement is
        // safely stored and will count when `updateFrame` brings the stack
        // there.
        guard rowWidth == width else { return }
        let oldHeight = heights[index]
        let delta = height - oldHeight
        guard delta != 0 else { return }
        let oldEnd = starts[index] + oldHeight
        // Row entirely above the visible part: what is on screen would shift
        // by `delta`. Absorb into the estimates further up first, then scroll.
        if oldEnd <= viewportTop {
            let remaining = absorbAbove(index: index, delta: delta)
            relayout(forceWindow: false)
            if remaining != 0 { compensateScroll(by: remaining) }
        } else {
            relayout(forceWindow: false)
        }
    }

    func setPinned(_ id: String, _ isPinned: Bool) {
        if isPinned { pinned.insert(id) } else { pinned.remove(id) }
        updateWindow(force: true)
        refreshPlan()
    }

    // MARK: - Plan for the panel

    /// Window to build and fillers for `specs`. Pure with respect to the
    /// observed state: if `specs` has not been committed yet (first
    /// evaluation of `body`, or rows just changed) it uses a provisional plan
    /// computed on the fly (only the rows that intersect the visible part, as
    /// `commit` will do), so the first pass already shows the right rows.
    func plan(for specs: [RewriteRowSpec]) -> Plan {
        if specs == rows { return currentPlan }
        let width = max(self.width, 1)
        let kept = Dictionary(rows.enumerated().compactMap { i, row in i < estimates.count ? (row.id, (row.shape, estimates[i])) : nil }, uniquingKeysWith: { first, _ in first })
        let temporaryHeights = specs.map { spec -> CGFloat in
            if let entry = measuredByWidth[self.width]?[spec.id], entry.shape == spec.shape { return entry.height }
            if let previous = kept[spec.id], previous.0 == spec.shape { return previous.1 }
            return RewriteRowHeightEstimator.estimate(spec.shape, width: width)
        }
        let (temporaryStarts, _) = Self.prefixSums(temporaryHeights)
        let range = neededRange(starts: temporaryStarts, heights: temporaryHeights, slack: 0, ids: specs.map(\.id))
        let measured = specs.map { spec -> CGFloat? in
            guard let entry = measuredByWidth[self.width]?[spec.id], entry.shape == spec.shape else { return nil }
            return entry.height
        }
        return Self.plan(starts: temporaryStarts, heights: temporaryHeights, measured: measured, range: range, tail: Self.scrollPastEndTail(viewportHeight: viewportHeight))
    }

    static func plan(starts: [CGFloat], heights: [CGFloat], measured: [CGFloat?], range: Range<Int>, tail: CGFloat = 0) -> Plan {
        let count = heights.count
        let clamped = range.clamped(to: 0 ..< count)
        guard count > 0, !clamped.isEmpty else { return .empty }
        let (_, total) = prefixSums(heights)
        let last = clamped.upperBound - 1
        let end = starts[last] + heights[last] + (last < count - 1 ? rowSpacing : 0)
        return Plan(range: clamped, topPadding: starts[clamped.lowerBound], bottomPadding: max(0, total - end) + tail, measuredHeights: clamped.map { measured[$0] }, modelHeights: clamped.map { heights[$0] })
    }

    // MARK: - Computation

    static func prefixSums(_ heights: [CGFloat]) -> (starts: [CGFloat], total: CGFloat) {
        var starts: [CGFloat] = []
        starts.reserveCapacity(heights.count)
        var y: CGFloat = 0
        for height in heights {
            starts.append(y)
            y += height + rowSpacing
        }
        return (starts, heights.isEmpty ? 0 : y - rowSpacing)
    }

    func measuredHeight(index: Int) -> CGFloat? {
        guard let entry = measuredByWidth[width]?[rows[index].id], entry.shape == rows[index].shape else { return nil }
        return entry.height
    }

    func relayout(forceWindow: Bool) {
        heights = rows.indices.map { measuredHeight(index: $0) ?? estimates[$0] }
        let sums = Self.prefixSums(heights)
        starts = sums.starts
        totalHeight = sums.total
        updateWindow(force: forceWindow)
        refreshPlan()
        schedulePublish()
    }

    /// Recomputes the plan and wakes the panel only if it has changed.
    func refreshPlan() {
        let next = Self.plan(starts: starts, heights: heights, measured: rows.indices.map { measuredHeight(index: $0) }, range: realizedRange, tail: Self.scrollPastEndTail(viewportHeight: viewportHeight))
        guard next != currentPlan else { return }
        currentPlan = next
        revision += 1
    }

    // MARK: - Diagnostics

    func height(of id: String) -> CGFloat? {
        guard let index = indexByID[id] else { return nil }
        return heights[index]
    }

    func isMeasured(_ id: String) -> Bool {
        guard let index = indexByID[id] else { return false }
        return measuredHeight(index: index) != nil
    }

    func publishFrames() {
        publishedFramesCount += 1
        model?.syncCoordinator.updatePanelRowFrames(rowFrames())
    }
}
