import Foundation
import Testing
@testable import LelePdf

/// Pure alignment math (SPEC §5.8: segment lookup, fraction, target
/// formula, clamping, gaps, 44 pt minimum).
@Suite("Sync: AlignmentModel")
struct AlignmentModelTests {
    private func twoSegments() -> [AlignmentSegment] {
        [
            AlignmentSegment(id: "a", pdfStart: 0, pdfHeight: 100, panelStart: 0, panelHeight: 50),
            AlignmentSegment(id: "b", pdfStart: 100, pdfHeight: 200, panelStart: 50, panelHeight: 80),
        ]
    }

    @Test("finds the right segment and the fraction within it")
    func segmentLookup() {
        let lookup = AlignmentModel.segmentAt(y: 150, side: .pdf, segments: twoSegments())
        #expect(lookup?.index == 1)
        #expect(lookup?.fraction == 0.25) // (150-100)/200
    }

    @Test("at the exact start of a segment the fraction is 0")
    func segmentLookupAtExactStart() {
        let lookup = AlignmentModel.segmentAt(y: 100, side: .pdf, segments: twoSegments())
        #expect(lookup?.index == 1)
        #expect(lookup?.fraction == 0)
    }

    @Test("before the first segment: stays on the first, with a negative fraction")
    func beforeFirstSegment() {
        let lookup = AlignmentModel.segmentAt(y: -20, side: .pdf, segments: twoSegments())
        #expect(lookup?.index == 0)
        #expect(lookup?.fraction == -0.2) // -20/100
    }

    @Test("after the last segment: stays on the last, with a fraction above 1")
    func afterLastSegment() {
        let lookup = AlignmentModel.segmentAt(y: 400, side: .pdf, segments: twoSegments())
        #expect(lookup?.index == 1)
        #expect(lookup?.fraction == 1.5) // (400-100)/200
    }

    @Test("in a gap between two segments: stays on the previous one, interpolating past 1 (SPEC 'gap between segments')")
    func gapBetweenSegments() {
        let segments = [
            AlignmentSegment(id: "a", pdfStart: 0, pdfHeight: 50, panelStart: 0, panelHeight: 50),
            AlignmentSegment(id: "b", pdfStart: 100, pdfHeight: 50, panelStart: 50, panelHeight: 50),
        ]
        let lookup = AlignmentModel.segmentAt(y: 75, side: .pdf, segments: segments)
        #expect(lookup?.index == 0)
        #expect(lookup?.fraction == 1.5) // (75-0)/50, still on the scale of segment "a"
    }

    @Test("the panel side uses its own intervals, not the PDF's")
    func panelSideUsesPanelIntervals() {
        let lookup = AlignmentModel.segmentAt(y: 70, side: .panel, segments: twoSegments())
        #expect(lookup?.index == 1)
        #expect(lookup?.fraction == 0.25) // (70-50)/80
    }

    @Test("no segments: nil")
    func emptySegmentsReturnsNil() {
        #expect(AlignmentModel.segmentAt(y: 10, side: .pdf, segments: []) == nil)
    }

    @Test("a zero-height segment does not divide by zero (title/Exhibit anchors)")
    func zeroHeightSegmentDoesNotCrash() {
        let segments = [AlignmentSegment(id: "a", pdfStart: 10, pdfHeight: 0, panelStart: 0, panelHeight: 0)]
        let lookup = AlignmentModel.segmentAt(y: 15, side: .pdf, segments: segments)
        #expect(lookup != nil)
        #expect(lookup?.fraction.isFinite == true)
    }

    @Test("target formula: start_B(i) + f × height_B(i) − reading line in B")
    func targetFormula() {
        let lookup = AlignmentModel.Lookup(index: 1, fraction: 0.25)
        let target = AlignmentModel.target(for: lookup, segments: twoSegments(), targetSide: .panel, readingLineOffset: 10, maxScroll: 1000)
        #expect(target == 60) // 50 + 0.25*80 - 10
    }

    @Test("the target never goes below zero")
    func targetClampedToZero() {
        let lookup = AlignmentModel.Lookup(index: 0, fraction: -1)
        let target = AlignmentModel.target(for: lookup, segments: twoSegments(), targetSide: .pdf, readingLineOffset: 0, maxScroll: 1000)
        #expect(target == 0)
    }

    @Test("the target never exceeds the maximum scroll")
    func targetClampedToMaxScroll() {
        let lookup = AlignmentModel.Lookup(index: 1, fraction: 5)
        let target = AlignmentModel.target(for: lookup, segments: twoSegments(), targetSide: .pdf, readingLineOffset: 0, maxScroll: 150)
        #expect(target == 150)
    }

    @Test("an index outside the given segments returns 0, does not crash")
    func targetOutOfRangeIndexIsSafe() {
        let lookup = AlignmentModel.Lookup(index: 9, fraction: 0)
        let target = AlignmentModel.target(for: lookup, segments: twoSegments(), targetSide: .pdf, readingLineOffset: 0, maxScroll: 1000)
        #expect(target == 0)
    }

    @Test("minimum height of unanalyzed placeholders (SPEC §5.6): 44pt, already guaranteed by RewriteViewModel")
    func placeholderMinimumHeightIsRespected() {
        // The Sync module does not recompute this constraint: it inherits it
        // from the real measured rectangles (RewriteScrollHost/
        // RowFramesPreferenceKey), which reflect
        // `BlockPlaceholderView.frame(minHeight:)`. Here we only check that the
        // shared constant has not drifted.
        #expect(RewriteViewModel.placeholderMinHeight == 44)
    }
}
