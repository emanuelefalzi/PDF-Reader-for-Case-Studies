import Testing
@testable import LelePdf

/// `AnnotationTextMarkupToggle` ("highlighter like Preview"): pure, no real
/// `PDFPage` needed — the PDFKit geometry is tested separately by
/// `AnnotationTextMarkupToggleRealEventTests`. Covers the interval math:
/// mark/unmark, shortening at one end, splitting in two, absorbing instead
/// of overlapping ("never a second layer"), and the mode decision from the
/// anchor.
@Suite("AnnotationTextMarkupToggle")
struct AnnotationTextMarkupToggleTests {
    private typealias Toggle = AnnotationTextMarkupToggle
    private typealias Range = AnnotationTextMarkupToggle.MarkRange
    private typealias Mark = AnnotationTextMarkupToggle.ExistingMark

    // MARK: - Mode from the anchor ("look at the state at the start of the selection")

    @Test("the anchor inside an existing mark → unmark mode")
    func anchorInsideExistingMarkMeansUnmark() {
        let marks = [Mark(id: "a1", range: Range(start: 10, end: 20))]
        #expect(Toggle.mode(anchor: 15, existingMarks: marks) == .unmark)
        // At the two ends: the start (inclusive) is "inside", the end
        // (exclusive, `[start, end)`) no longer is.
        #expect(Toggle.mode(anchor: 10, existingMarks: marks) == .unmark)
        #expect(Toggle.mode(anchor: 20, existingMarks: marks) == .mark)
    }

    @Test("the anchor outside every existing mark → mark mode")
    func anchorOutsideExistingMarksMeansMark() {
        let marks = [Mark(id: "a1", range: Range(start: 10, end: 20))]
        #expect(Toggle.mode(anchor: 5, existingMarks: marks) == .mark)
        #expect(Toggle.mode(anchor: 25, existingMarks: marks) == .mark)
    }

    @Test("no existing mark → always mark mode")
    func noExistingMarksMeansMark() {
        #expect(Toggle.mode(anchor: 3, existingMarks: []) == .mark)
    }

    // MARK: - "Mark" mode: simple case, no mark to absorb

    @Test("marking with no pre-existing marks simply creates the new selection")
    func markWithNoOverlapCreatesPlainRange() {
        let result = Toggle.apply(mode: .mark, newRange: Range(start: 10, end: 20), existingMarks: [])
        #expect(result.outcomes.isEmpty)
        #expect(result.newMarkRange == Range(start: 10, end: 20))
    }

    // MARK: - "Mark" mode: absorb instead of overlap

    @Test("marking over an overlapping mark ABSORBS it (no stacking): a single, wider mark")
    func markAbsorbsOverlappingMarkInsteadOfStacking() {
        let existing = [Mark(id: "a1", range: Range(start: 5, end: 15))]
        let result = Toggle.apply(mode: .mark, newRange: Range(start: 10, end: 25), existingMarks: existing)
        #expect(result.outcomes == ["a1": .removed])
        #expect(result.newMarkRange == Range(start: 5, end: 25))
    }

    @Test("marking over a merely ADJACENT mark (no gap in between) still merges it")
    func markMergesTouchingMark() {
        let existing = [Mark(id: "a1", range: Range(start: 0, end: 10))]
        let result = Toggle.apply(mode: .mark, newRange: Range(start: 10, end: 20), existingMarks: existing)
        #expect(result.outcomes == ["a1": .removed])
        #expect(result.newMarkRange == Range(start: 0, end: 20))
    }

    @Test("marking does NOT touch a truly separate mark (a real gap in between)")
    func markIgnoresTrulyDisjointMark() {
        let existing = [Mark(id: "a1", range: Range(start: 0, end: 5))]
        let result = Toggle.apply(mode: .mark, newRange: Range(start: 10, end: 20), existingMarks: existing)
        #expect(result.outcomes.isEmpty)
        #expect(result.newMarkRange == Range(start: 10, end: 20))
    }

    @Test("marking absorbs SEVERAL marks touched together, into a single mark")
    func markAbsorbsMultipleOverlappingMarks() {
        let existing = [
            Mark(id: "a1", range: Range(start: 0, end: 8)),
            Mark(id: "a2", range: Range(start: 25, end: 30)),
        ]
        let result = Toggle.apply(mode: .mark, newRange: Range(start: 5, end: 28), existingMarks: existing)
        #expect(result.outcomes == ["a1": .removed, "a2": .removed])
        #expect(result.newMarkRange == Range(start: 0, end: 30))
    }

    // MARK: - "Unmark" mode: delete/shorten/split

    @Test("unmarking a fully covered mark deletes it")
    func unmarkFullyCoveredMarkIsRemoved() {
        let existing = [Mark(id: "a1", range: Range(start: 5, end: 15))]
        let result = Toggle.apply(mode: .unmark, newRange: Range(start: 0, end: 20), existingMarks: existing)
        #expect(result.outcomes == ["a1": .removed])
        #expect(result.newMarkRange == nil)
    }

    @Test("unmarking the start of a mark shortens it, keeping the tail")
    func unmarkShrinksFromStart() {
        let existing = [Mark(id: "a1", range: Range(start: 10, end: 30))]
        let result = Toggle.apply(mode: .unmark, newRange: Range(start: 0, end: 20), existingMarks: existing)
        #expect(result.outcomes == ["a1": .resized(Range(start: 20, end: 30))])
    }

    @Test("unmarking the end of a mark shortens it, keeping the head")
    func unmarkShrinksFromEnd() {
        let existing = [Mark(id: "a1", range: Range(start: 10, end: 30))]
        let result = Toggle.apply(mode: .unmark, newRange: Range(start: 20, end: 40), existingMarks: existing)
        #expect(result.outcomes == ["a1": .resized(Range(start: 10, end: 20))])
    }

    @Test("unmarking the MIDDLE of a mark splits it into two pieces")
    func unmarkSplitsTheMiddleIntoTwoPieces() {
        let existing = [Mark(id: "a1", range: Range(start: 0, end: 30))]
        let result = Toggle.apply(mode: .unmark, newRange: Range(start: 10, end: 20), existingMarks: existing)
        #expect(result.outcomes == ["a1": .split(keep: Range(start: 0, end: 10), extra: Range(start: 20, end: 30))])
        #expect(result.newMarkRange == nil)
    }

    @Test("unmarking does not touch a mark the selection does not reach")
    func unmarkIgnoresUntouchedMark() {
        let existing = [Mark(id: "a1", range: Range(start: 0, end: 5)), Mark(id: "a2", range: Range(start: 40, end: 50))]
        let result = Toggle.apply(mode: .unmark, newRange: Range(start: 10, end: 20), existingMarks: existing)
        #expect(result.outcomes.isEmpty)
    }

    @Test("unmarking only the exact boundary (no character in common) deletes nothing")
    func unmarkExactBoundaryTouchDoesNothing() {
        let existing = [Mark(id: "a1", range: Range(start: 0, end: 10))]
        // `newRange` starts exactly where the mark ends: zero characters in
        // common, unlike "mark" mode where the same boundary causes absorption.
        let result = Toggle.apply(mode: .unmark, newRange: Range(start: 10, end: 20), existingMarks: existing)
        #expect(result.outcomes.isEmpty)
    }

    @Test("unmarking several marks touched together produces an independent outcome for each")
    func unmarkHandlesMultipleMarksIndependently() {
        let existing = [
            Mark(id: "a1", range: Range(start: 0, end: 10)), // fully covered
            Mark(id: "a2", range: Range(start: 15, end: 25)), // shortened from the start
        ]
        let result = Toggle.apply(mode: .unmark, newRange: Range(start: 0, end: 20), existingMarks: existing)
        #expect(result.outcomes == [
            "a1": .removed,
            "a2": .resized(Range(start: 20, end: 25)),
        ])
    }

    // MARK: - Basic `MarkRange`

    @Test("MarkRange normalizes end to be no earlier than start")
    func markRangeNeverHasNegativeLength() {
        let range = Range(start: 10, end: 3)
        #expect(range.end == 10)
        #expect(range.length == 0)
    }

    @Test("contains respects a half-open interval [start, end)")
    func containsIsHalfOpen() {
        let range = Range(start: 10, end: 20)
        #expect(range.contains(10))
        #expect(range.contains(19))
        #expect(!range.contains(20))
    }
}
