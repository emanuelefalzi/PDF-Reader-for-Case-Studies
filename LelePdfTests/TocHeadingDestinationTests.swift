import Foundation
import Testing
@testable import LelePdf

/// `TocHeadingDestination` (reported problem: the heading should end up at
/// the top of the screen): the computed destination point must bring the
/// heading near the top, with a small margin, never off the page.
@Suite("TocHeadingDestination")
struct TocHeadingDestinationTests {
    @Test("adds the margin above the heading's top edge")
    func addsTopMargin() {
        let point = TocHeadingDestination.point(pageY: 500, pageHeight: 792)
        #expect(point.y == 500 + TocHeadingDestination.topMargin)
        #expect(point.x == 0)
    }

    @Test("never exceeds the top of the page")
    func clampedAtPageTop() {
        let point = TocHeadingDestination.point(pageY: 790, pageHeight: 792)
        #expect(point.y == 792)
    }

    @Test("two headings on the same page give different destinations")
    func distinctDestinationsForTwoHeadingsOnSamePage() {
        let first = TocHeadingDestination.point(pageY: 700, pageHeight: 792)
        let second = TocHeadingDestination.point(pageY: 400, pageHeight: 792)
        #expect(first.y != second.y)
    }

    @Test("uses the left x of the given page")
    func usesGivenPageMinX() {
        let point = TocHeadingDestination.point(pageY: 100, pageHeight: 792, pageMinX: 12)
        #expect(point.x == 12)
    }
}
