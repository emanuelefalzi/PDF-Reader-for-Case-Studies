import Foundation
@preconcurrency import PDFKit

/// Builds highlight/underline/strikethrough from a `PDFSelection`
/// (SPEC §5.13): shared by `AnnotationOverlayView+TextMarkup.swift`
/// (dragging with the Highlight tool active) and by the selection mini bar
/// of §5.7 (`MarksOverlaySelectionBar`, third group: text tools also appear
/// in the selection mini bar).
///
/// **Highlighter that behaves like Preview's**: it no longer
/// unconditionally creates a new annotation. Instead it applies
/// `AnnotationTextMarkupToggle` (pure, tested on its own) to decide whether
/// to mark or unmark, then translates the result into PDFKit geometry and
/// applies it as ONE SINGLE group (`AnnotationController.applyGroup`): one
/// ⌘Z for the whole operation, even when it includes a split into two
/// pieces or spans several pages.
@MainActor
enum AnnotationTextMarkupCreator {
    static func apply(kind: AnnotationKind, selection: PDFSelection, document: PDFDocument, controller: AnnotationController, color: AnnotationColor? = nil) {
        // 1. The selection's lines grouped by page, in the ORDER PDFKit
        // returns them (`selectionsByLine()`): for dragging with the Annotate
        // bar this reflects the start→end order passed to
        // `document.selection(from:at:to:at:)`, that is, the real anchor of
        // the mouse gesture. The first page/line encountered is "the start
        // of the selection" (the mode is decided from the state there). For
        // a native selection coming from elsewhere (mini bar,
        // keyboard/accessibility) PDFKit does not guarantee that this
        // matches the direction read from the mouse in a backward drag: a
        // known limitation.
        var pageOrder: [Int] = []
        var linesByPage: [Int: [PDFSelection]] = [:]
        for lineSelection in selection.selectionsByLine() {
            guard let page = lineSelection.pages.first else { continue }
            let index = document.index(for: page)
            guard index != NSNotFound else { continue }
            if linesByPage[index] == nil { pageOrder.append(index) }
            linesByPage[index, default: []].append(lineSelection)
        }
        guard !pageOrder.isEmpty else { return }

        var rangesByPage: [Int: AnnotationTextRange] = [:]
        for page in pageOrder {
            guard let pdfPage = document.page(at: page) else { continue }
            rangesByPage[page] = AnnotationTextRangeResolver.range(forLines: linesByPage[page] ?? [], page: pdfPage)
        }
        // If not even the anchor point can be resolved, there is no safe way
        // to decide mark/unmark: no operation (SPEC "never a guessed
        // action").
        guard let anchorPage = pageOrder.first,
              let anchorPdfPage = document.page(at: anchorPage),
              let anchorRange = rangesByPage[anchorPage] else { return }

        // 2. Mode: decided ONCE, from the state at the first
        // character of the anchor page. Color never matters when recognizing
        // "the same tool": `familyMarks` filters by `AnnotationKind` only.
        let anchorFamily = familyMarks(in: controller.annotations, page: anchorPage, kind: kind, pdfPage: anchorPdfPage)
            .map { AnnotationTextMarkupToggle.ExistingMark(id: $0.id, range: AnnotationTextMarkupToggle.MarkRange($0.range)) }
        let mode = AnnotationTextMarkupToggle.mode(anchor: anchorRange.start, existingMarks: anchorFamily)

        var edits: [AnnotationEdit] = []
        let nextId = AnnotationIdentifiers.sequentialIdGenerator(in: controller.annotations)

        for page in pageOrder {
            guard let newRange = rangesByPage[page], let pdfPage = document.page(at: page) else { continue }
            let family = familyMarks(in: controller.annotations, page: page, kind: kind, pdfPage: pdfPage)
            let result = AnnotationTextMarkupToggle.apply(
                mode: mode,
                newRange: AnnotationTextMarkupToggle.MarkRange(newRange),
                existingMarks: family.map { AnnotationTextMarkupToggle.ExistingMark(id: $0.id, range: AnnotationTextMarkupToggle.MarkRange($0.range)) }
            )

            for (id, outcome) in result.outcomes {
                guard let original = controller.annotations.first(where: { $0.id == id }) else { continue }
                switch outcome {
                case .removed:
                    edits.append(AnnotationEdit(annotationId: id, before: original, after: nil))
                case .resized(let range):
                    guard let updated = remade(original, range: range.annotationTextRange, page: pdfPage) else { continue }
                    edits.append(AnnotationEdit(annotationId: id, before: original, after: updated))
                case .split(let keep, let extra):
                    guard let kept = remade(original, range: keep.annotationTextRange, page: pdfPage),
                          let extraPiece = remade(original, range: extra.annotationTextRange, page: pdfPage, newId: nextId())
                    else { continue }
                    edits.append(AnnotationEdit(annotationId: id, before: original, after: kept))
                    edits.append(AnnotationEdit(annotationId: extraPiece.id, before: nil, after: extraPiece))
                }
            }

            if mode == .mark, let newMarkRange = result.newMarkRange,
               let created = makeNewMark(kind: kind, page: page, range: newMarkRange.annotationTextRange, pdfPage: pdfPage, id: nextId(), color: color, controller: controller) {
                edits.append(AnnotationEdit(annotationId: created.id, before: nil, after: created))
            }
        }

        guard !edits.isEmpty else { return }
        controller.applyGroup(edits, actionName: actionName(for: kind, mode: mode))
    }

    /// Existing marks of the same family on this page (any color).
    /// Annotations written by LelePdf always carry `textRange` (they were
    /// built by `AnnotationController+Tools.createTextMarkup`, now this same
    /// file); those imported from Preview (`PDFAnnotationImporter`) already
    /// have one resolved at import time, but an older `annotazioni.json` may
    /// lack one, in which case it is rebuilt on the fly from the geometry as
    /// a last resort.
    private static func familyMarks(in annotations: [Annotation], page: Int, kind: AnnotationKind, pdfPage: PDFPage) -> [(id: String, range: AnnotationTextRange)] {
        annotations.compactMap { annotation -> (id: String, range: AnnotationTextRange)? in
            guard annotation.page == page, annotation.kind == kind else { return nil }
            if let range = annotation.textRange { return (annotation.id, range) }
            guard let range = AnnotationTextRangeResolver.range(for: annotation.rect.cgRect, on: pdfPage) else { return nil }
            return (annotation.id, range)
        }
    }

    /// Geometry (quad per line, bounding box, text) for any character range
    /// of the page. Used both to rebuild an existing mark that was shortened
    /// or split, and to create a new one: `page.selection(for range:)`
    /// (`selectionForRange:`) converts the range into a `PDFSelection`, then
    /// it proceeds like any dragged selection (`selectionsByLine()`).
    private static func markupGeometry(page: PDFPage, range: AnnotationTextRange) -> (rect: CGRect, quads: [CGRect], text: String?)? {
        guard range.length > 0,
              let selection = page.selection(for: NSRange(location: range.start, length: range.length))
        else { return nil }
        let lines = selection.selectionsByLine()
        guard !lines.isEmpty else { return nil }
        let quads = lines.map { $0.bounds(for: page) }
        let rect = quads.reduce(quads[0]) { $0.union($1) }
        let text = lines.compactMap(\.string).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (rect, quads, text.isEmpty ? nil : text)
    }

    /// An existing mark, shortened/split: same id (or `newId` for the second
    /// piece of a split), same kind/color/other properties, geometry/text
    /// recomputed for the new range.
    private static func remade(_ original: Annotation, range: AnnotationTextRange, page: PDFPage, newId: String? = nil) -> Annotation? {
        guard let geometry = markupGeometry(page: page, range: range) else { return nil }
        var updated = original
        updated.id = newId ?? original.id
        updated.rect = AnnotationRect(geometry.rect)
        updated.quads = geometry.quads.map(AnnotationRect.init)
        updated.textRange = range
        updated.text = geometry.text
        let now = Date()
        updated.updatedAt = now
        if newId != nil { updated.createdAt = now }
        return updated
    }

    /// New mark ("mark" mode): same color as the active tool (or the explicit
    /// one passed by the selection mini bar, as already done by
    /// `AnnotationController+Tools.createTextMarkup`), never that of an
    /// absorbed mark: absorbing does NOT mean inheriting the old color
    /// (merging instead of stacking: a single mark, in the color of the
    /// current operation).
    private static func makeNewMark(kind: AnnotationKind, page: Int, range: AnnotationTextRange, pdfPage: PDFPage, id: String, color: AnnotationColor?, controller: AnnotationController) -> Annotation? {
        guard let geometry = markupGeometry(page: pdfPage, range: range) else { return nil }
        let resolvedColor = color ?? controller.currentColor.color(alpha: kind == .highlight ? AnnotationPaletteColor.highlightAlpha : 1)
        return Annotation(
            id: id, page: page, kind: kind, color: resolvedColor, rect: AnnotationRect(geometry.rect),
            textRange: range, quads: geometry.quads.map(AnnotationRect.init), text: geometry.text
        )
    }

    private static func actionName(for kind: AnnotationKind, mode: AnnotationTextMarkupToggle.Mode) -> String {
        let tool = switch kind {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeout: "Strikethrough"
        default: "Text Annotation"
        }
        return mode == .mark ? tool : "Remove \(tool)"
    }
}
