import AppKit
import Testing
@preconcurrency import PDFKit
@testable import LelePdf

extension HeavyTestSuites {
@MainActor
@Suite("Pen from real events", .serialized)
struct AnnotationInkRealEventTests {
    @Test("the Pen works across the window/mark/section matrix and the stroke is visible")
    func inkWorksThroughNSWindowSendEvent() throws {
        for windowState in AnnotationRealEventHarness.WindowState.allCases {
            for withMark in [false, true] {
                for insideAnalyzedSection in [false, true] {
                    let label = "\(windowState)-mark:\(withMark)-analyzed:\(insideAnalyzedSection)"
                    let scene = try AnnotationRealEventHarness(
                        windowState: windowState,
                        withMark: withMark,
                        insideAnalyzedSection: insideAnalyzedSection
                    )
                    defer { scene.teardown() }
                    let controller = scene.model.annotationController
                    controller.barVisible = true
                    controller.selectTool(.ink)
                    let start = CGPoint(x: 45, y: 95)
                    // For the Pen the matrix's mark is seeded on the text at y=150; we
                    // start the stroke there when needed, and away from the text in the
                    // no-mark variant.
                    let gestureStart = withMark ? CGPoint(x: 45, y: 150) : start
                    #expect(scene.hasMark(at: gestureStart) == withMark)
                    #expect(scene.sectionIsAnalyzed == insideAnalyzedSection)

                    scene.drag(
                        from: gestureStart,
                        to: CGPoint(x: 190, y: 125),
                        steps: 8
                    )

                    let created = try #require(
                        controller.annotations.last(where: { $0.kind == .ink }),
                        "\(label): the real drag must create the stroke"
                    )
                    #expect((created.points?.count ?? 0) >= 2, "\(label): the stroke must keep more than one point")
                    let native = try #require(
                        scene.ownedPDFAnnotation(id: created.id),
                        "\(label): the renderer must add the native Ink annotation"
                    )
                    let path = try #require(native.paths?.first, "\(label): the Ink annotation must contain a path")
                    let localBounds = CGRect(origin: .zero, size: native.bounds.size)
                        .insetBy(dx: -0.5, dy: -0.5)
                    #expect(
                        localBounds.contains(path.bounds),
                        "\(label): PDFKit wants the path relative to the annotation's origin, not page coordinates"
                    )
                }
            }
        }
    }

    @Test("line and arrow too use the local coordinates PDFKit requires")
    func lineEndpointsAreAnnotationLocal() {
        for kind in [AnnotationKind.line, .arrow] {
            let model = Annotation(
                id: "a1", page: 0, kind: kind,
                color: AnnotationPaletteColor.blue.color(), lineWidth: 3,
                rect: AnnotationRect(x: 96, y: 196, width: 128, height: 58),
                points: [AnnotationPoint(x: 100, y: 200), AnnotationPoint(x: 220, y: 250)]
            )
            let native = AnnotationBuilder.makePDFAnnotation(for: model)
            let localBounds = CGRect(origin: .zero, size: native.bounds.size)
            #expect(localBounds.contains(native.startPoint))
            #expect(localBounds.contains(native.endPoint))
        }
    }
}
}
