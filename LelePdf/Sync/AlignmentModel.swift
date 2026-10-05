import Foundation

/// Side that drives the linked scrolling (SPEC §5.8): "Both sides can
/// drive".
enum SyncSide: Sendable, Equatable {
    case pdf, panel
}

/// One segment of the ordered sequence (chapter/section titles, blocks,
/// Exhibit references; SPEC §5.8 "Alignment model"): a continuous vertical
/// interval on each side, in a common "scrolling downward" space (y = 0 at
/// the top of the document/content, growing downward); see
/// `SyncGeometry.DocumentSpace` for how the two sides (PDFKit flipped or
/// not; the right panel always flipped, `RewriteFlippedHostingView`) are
/// brought into this same system. Pure: no dependency on PDFKit/AppKit, so
/// it is testable on its own (alignment math).
struct AlignmentSegment: Sendable, Equatable, Identifiable {
    let id: String
    var pdfStart: CGFloat
    var pdfHeight: CGFloat
    var panelStart: CGFloat
    var panelHeight: CGFloat

    var pdfEnd: CGFloat { pdfStart + pdfHeight }
    var panelEnd: CGFloat { panelStart + panelHeight }
}

/// Pure alignment math (SPEC §5.8 "When the user scrolls one side"). No
/// state: all functions take the sequence of segments as a parameter.
enum AlignmentModel {
    /// Segment *i* that contains the reading line, and the fraction *f*
    /// traversed within it ("segmentAt(y:side:) → (index, fraction f)").
    struct Lookup: Sendable, Equatable {
        var index: Int
        var fraction: CGFloat
    }

    /// Minimum height used in the denominator, to avoid dividing by zero on
    /// zero-height segments (the anchor points of titles/Exhibits, see
    /// `AlignmentBuilder`).
    static let minSegmentHeight: CGFloat = 0.5

    /// Finds the segment that contains (or most closely precedes) `y` on
    /// `side`, and the fraction within it. `segments` must be sorted by
    /// non-decreasing start on both sides (guaranteed by `AlignmentBuilder`,
    /// which derives them from the same document order).
    ///
    /// It does not treat "before the first/after the last/in the gaps
    /// between segments" as special cases: it always takes the last segment
    /// whose start is ≤ `y` (the first if `y` falls before all of them) and
    /// lets the fraction go outside [0,1): negative before the segment,
    /// above 1 inside a gap after its end. This way extrapolation uses that
    /// segment's per-point scale instead of an abrupt jump; `target(for:...)`
    /// then adds the only guard that is really needed, the end of the scale
    /// (SPEC "clamped to the scrollable range").
    static func segmentAt(y: CGFloat, side: SyncSide, segments: [AlignmentSegment]) -> Lookup? {
        guard !segments.isEmpty else { return nil }
        var index = 0
        for (offset, segment) in segments.enumerated() where start(of: segment, side: side) <= y {
            index = offset
        }
        let segment = segments[index]
        let height = max(end(of: segment, side: side) - start(of: segment, side: side), minSegmentHeight)
        let fraction = (y - start(of: segment, side: side)) / height
        return Lookup(index: index, fraction: fraction)
    }

    /// `target_B = start_B(i) + f × height_B(i) − position of the reading
    /// line in B`, clamped to `[0, maxScroll]` (SPEC §5.8 exact formula).
    /// `targetSide` is the side that receives the scroll (the other one from
    /// the one that produced `lookup`).
    static func target(
        for lookup: Lookup, segments: [AlignmentSegment], targetSide: SyncSide,
        readingLineOffset: CGFloat, maxScroll: CGFloat
    ) -> CGFloat {
        guard segments.indices.contains(lookup.index) else { return 0 }
        let segment = segments[lookup.index]
        let segStart = start(of: segment, side: targetSide)
        let segEnd = end(of: segment, side: targetSide)
        let height = max(segEnd - segStart, minSegmentHeight)
        let raw = segStart + lookup.fraction * height - readingLineOffset
        return min(max(raw, 0), max(maxScroll, 0))
    }

    /// Actual deviation, in the target side's space, between the
    /// corresponding point required by the formula and the reading line
    /// after the applied scroll. It stays meaningful even when clamping at
    /// the edge leaves the line inside the same segment: that case could be
    /// hundreds of points away while being measured as zero.
    static func offsetAfterApplying(
        _ lookup: Lookup,
        segments: [AlignmentSegment],
        targetSide: SyncSide,
        appliedTop: CGFloat,
        readingLineOffset: CGFloat
    ) -> CGFloat {
        guard segments.indices.contains(lookup.index) else { return 0 }
        let segment = segments[lookup.index]
        let segStart = start(of: segment, side: targetSide)
        let segEnd = end(of: segment, side: targetSide)
        let height = max(segEnd - segStart, minSegmentHeight)
        let expectedY = segStart + lookup.fraction * height
        let actualY = appliedTop + readingLineOffset
        return abs(expectedY - actualY)
    }

    private static func start(of segment: AlignmentSegment, side: SyncSide) -> CGFloat {
        side == .pdf ? segment.pdfStart : segment.panelStart
    }

    private static func end(of segment: AlignmentSegment, side: SyncSide) -> CGFloat {
        side == .pdf ? segment.pdfEnd : segment.panelEnd
    }
}
