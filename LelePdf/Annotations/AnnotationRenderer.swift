import AppKit
@preconcurrency import PDFKit

/// Draws the model's annotations as NATIVE `PDFAnnotation`s on the open
/// `PDFDocument`. This renderer stays in memory only; the PDF write uses a
/// fresh copy and `PDFAnnotationWriteService`, never this view.
/// Same technique as `Reader/DebugOverlay.swift`:
/// `PDFView.pageOverlayViewProvider` is not reliable in this configuration,
/// `PDFAnnotation`s are.
///
/// Custom key `LelePdfAnnotationId` (`annotationKeyValues`) to distinguish
/// these annotations from the debug ones (`DebugBlockAnnotator`, which
/// keeps its own separate list anyway and never touches these) and to find/
/// update the `PDFAnnotation` of an already-drawn id without redrawing the
/// whole page on every gesture.
@MainActor
final class AnnotationRenderer {
    private weak var document: PDFDocument?
    /// PDFKit annotation drawn for each model id, for a targeted update
    /// (`refresh(_:)`) instead of redrawing the entire page on every dragged
    /// pixel (SPEC §9 "60 fps").
    private var drawn: [String: PDFAnnotation] = [:]

    init(document: PDFDocument) {
        self.document = document
    }

    /// Rebuilds all annotations from scratch (document open, SPEC "recreated
    /// from `annotazioni.json` on every open").
    func refreshAll(_ annotations: [Annotation]) {
        clear()
        for annotation in annotations where annotation.externalPDFIdentifier == nil { add(annotation) }
    }

    /// Syncs the drawing with the model's current state: adds the new ones,
    /// updates the changed ones, removes the vanished ones. Used on every
    /// `onAnnotationsChanged` (creation, live drag, undo/redo): the
    /// alternative (`refreshAll` on every tick) would redraw all visible
    /// pages even for a single pixel of movement.
    func sync(_ annotations: [Annotation]) {
        PerfProbe.measure("annot.renderer.sync") { syncBody(annotations) }
    }

    private func syncBody(_ annotations: [Annotation]) {
        let localAnnotations = annotations.filter { $0.externalPDFIdentifier == nil }
        let currentIds = Set(localAnnotations.map(\.id))
        for id in drawn.keys where !currentIds.contains(id) { remove(id: id) }
        for annotation in localAnnotations {
            if drawn[annotation.id] != nil {
                update(annotation)
            } else {
                add(annotation)
            }
        }
    }

    private func clear() {
        guard let document else { drawn.removeAll(); return }
        for (_, annotation) in drawn {
            annotation.page?.removeAnnotation(annotation)
        }
        drawn.removeAll()
        _ = document
    }

    private func add(_ model: Annotation) {
        guard let document, let page = document.page(at: model.page) else { return }
        let pdfAnnotation = AnnotationBuilder.makePDFAnnotation(for: model)
        PDFAnnotationOwnership.tag(pdfAnnotation, role: .freeAnnotation, id: model.id)
        page.addAnnotation(pdfAnnotation)
        drawn[model.id] = pdfAnnotation
    }

    private func update(_ model: Annotation) {
        guard let existing = drawn[model.id] else { return }
        // PDFKit offers no reliable way to "update in place" every property
        // of every subtype (bounds yes, but shape style, pen points and
        // color do not always apply after creation, per the PDFKit
        // documentation): we remove and recreate, which is simpler and still
        // cheap (only the touched annotation, not the whole page).
        existing.page?.removeAnnotation(existing)
        add(model)
    }

    private func remove(id: String) {
        guard let existing = drawn[id] else { return }
        existing.page?.removeAnnotation(existing)
        drawn.removeValue(forKey: id)
    }
}
