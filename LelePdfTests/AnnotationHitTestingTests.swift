import Testing
import CoreGraphics
@testable import LelePdf

/// `AnnotationHitTesting` for each kind (SPEC §5.13 "Selection: click
/// selects (hit-testing per kind)"). Pure.
@Suite("AnnotationHitTesting")
struct AnnotationHitTestingTests {
    private func makeAnnotation(
        kind: AnnotationKind, rect: CGRect, fillColor: AnnotationColor? = nil, points: [CGPoint]? = nil, quads: [CGRect]? = nil
    ) -> Annotation {
        Annotation(
            id: "a1", page: 0, kind: kind, color: AnnotationColor(red: 0, green: 0, blue: 0, alpha: 1), fillColor: fillColor,
            rect: AnnotationRect(rect), quads: quads?.map(AnnotationRect.init), points: points?.map(AnnotationPoint.init)
        )
    }

    @Test("a highlight is hit inside its own quad")
    func highlightHitsInsideQuad() {
        let annotation = makeAnnotation(kind: .highlight, rect: CGRect(x: 0, y: 0, width: 100, height: 10), quads: [CGRect(x: 0, y: 0, width: 100, height: 10)])
        #expect(AnnotationHitTesting.hitTest(annotation, point: CGPoint(x: 50, y: 5)))
        #expect(!AnnotationHitTesting.hitTest(annotation, point: CGPoint(x: 200, y: 5)))
    }

    @Test("an unfilled rectangle is hit only on its border, not in the center")
    func unfilledRectangleHitsOnlyBorder() {
        let annotation = makeAnnotation(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(AnnotationHitTesting.hitTest(annotation, point: CGPoint(x: 0, y: 50))) // on the left border
        #expect(!AnnotationHitTesting.hitTest(annotation, point: CGPoint(x: 50, y: 50))) // in the center, empty
    }

    @Test("a filled rectangle is also hit in the center")
    func filledRectangleHitsInterior() {
        let annotation = makeAnnotation(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 100), fillColor: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(AnnotationHitTesting.hitTest(annotation, point: CGPoint(x: 50, y: 50)))
    }

    @Test("a line is hit within tolerance of the stroke, not far away")
    func lineHitsWithinTolerance() {
        let annotation = makeAnnotation(kind: .line, rect: CGRect(x: 0, y: 0, width: 100, height: 1), points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        #expect(AnnotationHitTesting.hitTest(annotation, point: CGPoint(x: 50, y: 2)))
        #expect(!AnnotationHitTesting.hitTest(annotation, point: CGPoint(x: 50, y: 50)))
    }

    @Test("a pen stroke is hit along the polyline")
    func inkHitsAlongPolyline() {
        let annotation = makeAnnotation(kind: .ink, rect: CGRect(x: 0, y: 0, width: 100, height: 100), points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0)])
        #expect(AnnotationHitTesting.hitTest(annotation, point: CGPoint(x: 25, y: 25)))
        #expect(!AnnotationHitTesting.hitTest(annotation, point: CGPoint(x: 25, y: 90)))
    }

    @Test("a textbox/note is hit inside its own rect")
    func textboxAndNoteHitInsideRect() {
        let textbox = makeAnnotation(kind: .textbox, rect: CGRect(x: 0, y: 0, width: 60, height: 20))
        #expect(AnnotationHitTesting.hitTest(textbox, point: CGPoint(x: 30, y: 10)))
        let note = makeAnnotation(kind: .note, rect: CGRect(x: 0, y: 0, width: 22, height: 22))
        #expect(AnnotationHitTesting.hitTest(note, point: CGPoint(x: 11, y: 11)))
    }

    @Test("topmostHit returns the last created annotation among those hit")
    func topmostHitReturnsLast() {
        let first = makeAnnotation(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 100), fillColor: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1))
        var second = makeAnnotation(kind: .ellipse, rect: CGRect(x: 20, y: 20, width: 40, height: 40), fillColor: AnnotationColor(red: 0, green: 1, blue: 0, alpha: 1))
        second.id = "a2"
        let hit = AnnotationHitTesting.topmostHit([first, second], page: 0, point: CGPoint(x: 30, y: 30))
        #expect(hit?.id == "a2")
    }

    @Test("topmostHit ignores annotations on another page")
    func topmostHitFiltersByPage() {
        var other = makeAnnotation(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 100), fillColor: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 1))
        other.page = 1
        let hit = AnnotationHitTesting.topmostHit([other], page: 0, point: CGPoint(x: 50, y: 50))
        #expect(hit == nil)
    }

    // MARK: - "Delete" (X) button

    @Test("only notes and textboxes have the delete button")
    func onlyNoteAndTextboxHaveDeleteButton() {
        let note = makeAnnotation(kind: .note, rect: CGRect(x: 0, y: 0, width: 22, height: 22))
        let textbox = makeAnnotation(kind: .textbox, rect: CGRect(x: 0, y: 0, width: 60, height: 20))
        let rectangle = makeAnnotation(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 60, height: 20))
        #expect(AnnotationHitTesting.hitsDeleteButton(note, point: CGPoint(x: 22, y: 22)))
        #expect(AnnotationHitTesting.hitsDeleteButton(textbox, point: CGPoint(x: 60, y: 20)))
        #expect(!AnnotationHitTesting.hitsDeleteButton(rectangle, point: CGPoint(x: 60, y: 20)), "a shape has no X button, it is deleted with ⌫/menu as in Preview")
    }

    @Test("deleteButtonHit only looks among the candidates (selected/hovered), not among all annotations")
    func deleteButtonHitOnlyAmongCandidates() {
        var note1 = makeAnnotation(kind: .note, rect: CGRect(x: 0, y: 0, width: 22, height: 22))
        note1.id = "n1"
        var note2 = makeAnnotation(kind: .note, rect: CGRect(x: 100, y: 0, width: 22, height: 22))
        note2.id = "n2"
        let point = CGPoint(x: 122, y: 22) // corner of note2

        #expect(AnnotationHitTesting.deleteButtonHit([note1, note2], candidateIds: ["n2"], page: 0, point: point)?.id == "n2")
        #expect(AnnotationHitTesting.deleteButtonHit([note1, note2], candidateIds: ["n1"], page: 0, point: point) == nil, "n1 is not a candidate: even if something touched its button, it must not be found here")
        #expect(AnnotationHitTesting.deleteButtonHit([note1, note2], candidateIds: [], page: 0, point: point) == nil)
    }
}
