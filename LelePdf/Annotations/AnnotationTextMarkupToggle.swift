import Foundation

/// "Like Preview" rule for highlight/underline/strikethrough (user
/// request: "when I go over it again the color comes off, rather than
/// getting darker"): selecting UNmarked text with the active tool marks it;
/// selecting text ALREADY marked with the SAME tool unmarks it
/// (deletes/shortens/splits the existing mark), NEVER a second layer on the
/// same text.
///
/// **Mixed selection** (partly marked, partly not; the proposal was
/// confirmed): the mode of the WHOLE operation is decided by looking at the
/// state at the START of the selection, not stretch by stretch. If the
/// start is already marked → unmark (remove/shorten/split) every mark of
/// the same family touched by the selection, and create nothing new where
/// there was no mark already. If the start is not marked → mark the whole
/// selection, ABSORBING (not overlaying) every existing mark of the same
/// family that the selection touches or touches the edge of ("merging with
/// adjacent/overlapping ... instead of stacking").
///
/// **Color** (decided): a mark with the same tool but a different color
/// counts as "the same kind" for this rule: the caller
/// (`AnnotationTextMarkupCreator`) filters the existing marks by
/// `AnnotationKind` only, never by color, before passing them here.
///
/// Pure (no dependency on PDFKit/AppKit): operates only on character ranges
/// (`MarkRange`, the same unit as `AnnotationTextRange`), leaving to the
/// PDFKit geometry (`AnnotationTextMarkupCreator`, `page.selection(for
/// range:)`) the conversion to/from quad/rect/text. Testable on its own,
/// without a real `PDFPage`.
enum AnnotationTextMarkupToggle {
    enum Mode: Equatable { case mark, unmark }

    /// `[start, end)` range of characters (half-open, like `NSRange` but with
    /// an explicit upper bound instead of a length: more convenient for the
    /// intersection/union operations below).
    struct MarkRange: Equatable {
        var start: Int
        var end: Int

        init(start: Int, end: Int) {
            self.start = start
            self.end = max(start, end)
        }

        init(_ range: AnnotationTextRange) {
            self.init(start: range.start, end: range.start + range.length)
        }

        var length: Int { end - start }
        var annotationTextRange: AnnotationTextRange { AnnotationTextRange(start: start, length: length) }

        /// TRUE overlap (at least one character in common): used to decide
        /// whether to unmark an existing mark.
        func overlaps(_ other: MarkRange) -> Bool { start < other.end && end > other.start }

        /// Overlap or just a shared boundary ("merging with adjacent ...
        /// marks"): used to decide whether to absorb an existing mark while
        /// marking, so that two marks that "just touch" become a single mark
        /// instead of staying separate.
        func touchesOrOverlaps(_ other: MarkRange) -> Bool { start <= other.end && end >= other.start }

        func contains(_ position: Int) -> Bool { position >= start && position < end }
    }

    struct ExistingMark: Equatable {
        var id: String
        var range: MarkRange
    }

    enum Outcome: Equatable {
        /// The existing mark disappears entirely: either the new selection
        /// covered it entirely (unmark), or it was absorbed into a single
        /// wider mark (mark, "merging ... instead of stacking").
        case removed
        /// The existing mark stays ONE single annotation (same id), but with
        /// a shorter range: the selection covered only one end of it.
        case resized(MarkRange)
        /// The selection fell in the MIDDLE of the existing mark: it stays as
        /// `keep` (same id), and a SECOND mark is born for `extra` (same
        /// kind/color as the original, new id assigned by the caller).
        case split(keep: MarkRange, extra: MarkRange)
    }

    struct Result: Equatable {
        var mode: Mode
        /// Only the existing marks TOUCHED by the operation (id -> outcome);
        /// a family id not present here stays unchanged.
        var outcomes: [String: Outcome]
        /// Range of the mark to CREATE: the union of the selection with every
        /// absorbed mark. Always present in "mark" mode (even with no marks
        /// to absorb, it then coincides with the selection itself); always
        /// `nil` in "unmark" mode: nothing new is ever created while
        /// removing a mark.
        var newMarkRange: MarkRange?
    }

    /// State at the start of the selection (the mode is decided by looking
    /// there): true if `position` falls inside AT LEAST one of the existing
    /// marks of the same family (any color, by the caller's construction).
    static func isPosition(_ position: Int, markedBy marks: [ExistingMark]) -> Bool {
        marks.contains { $0.range.contains(position) }
    }

    static func mode(anchor position: Int, existingMarks: [ExistingMark]) -> Mode {
        isPosition(position, markedBy: existingMarks) ? .unmark : .mark
    }

    /// Applies the rule to ONE page: `existingMarks` is already filtered by
    /// the caller by `AnnotationKind`/page (never by color).
    static func apply(mode: Mode, newRange: MarkRange, existingMarks: [ExistingMark]) -> Result {
        switch mode {
        case .unmark:
            var outcomes: [String: Outcome] = [:]
            for mark in existingMarks where mark.range.overlaps(newRange) {
                // Single formula for the 4 cases (no remainder/left
                // remainder/right remainder/split in two): the part of
                // `mark.range` that falls BEFORE `newRange` and the part
                // that falls AFTER, each truncated to zero if there is none.
                let leftLength = max(0, min(mark.range.end, newRange.start) - mark.range.start)
                let rightLength = max(0, mark.range.end - max(mark.range.start, newRange.end))
                switch (leftLength > 0, rightLength > 0) {
                case (false, false):
                    outcomes[mark.id] = .removed
                case (true, false):
                    outcomes[mark.id] = .resized(MarkRange(start: mark.range.start, end: mark.range.start + leftLength))
                case (false, true):
                    outcomes[mark.id] = .resized(MarkRange(start: mark.range.end - rightLength, end: mark.range.end))
                case (true, true):
                    outcomes[mark.id] = .split(
                        keep: MarkRange(start: mark.range.start, end: mark.range.start + leftLength),
                        extra: MarkRange(start: mark.range.end - rightLength, end: mark.range.end)
                    )
                }
            }
            return Result(mode: .unmark, outcomes: outcomes, newMarkRange: nil)

        case .mark:
            var outcomes: [String: Outcome] = [:]
            var unionStart = newRange.start
            var unionEnd = newRange.end
            for mark in existingMarks where mark.range.touchesOrOverlaps(newRange) {
                outcomes[mark.id] = .removed
                unionStart = min(unionStart, mark.range.start)
                unionEnd = max(unionEnd, mark.range.end)
            }
            return Result(mode: .mark, outcomes: outcomes, newMarkRange: MarkRange(start: unionStart, end: unionEnd))
        }
    }
}
