import AppKit
import Testing
@preconcurrency import PDFKit
@testable import LelePdf

/// Regression for real user feedback: every case sends mouse-down, drag
/// and mouse-up to the window. No direct call to `mouseDown`,
/// `AnnotationTextMarkupCreator` or `AnnotationController` can make these
/// tests pass by bypassing the AppKit routing that was broken.
extension HeavyTestSuites {
@MainActor
@Suite("Text markup from real events", .serialized)
struct AnnotationTextMarkupRealEventTests {
    private static let tools: [(AnnotationTool, AnnotationKind)] = [
        (.highlight, .highlight),
        (.underline, .underline),
        (.strikeout, .strikeout),
    ]

    @Test("Highlight, Underline and Strikethrough work across the window/mark/section matrix")
    func everyTextMarkupToolWorksThroughNSWindowSendEvent() throws {
        for (tool, kind) in Self.tools {
            for windowState in AnnotationRealEventHarness.WindowState.allCases {
                for withMark in [false, true] {
                    for insideAnalyzedSection in [false, true] {
                        let label = "\(tool)-\(windowState)-mark:\(withMark)-analyzed:\(insideAnalyzedSection)"
                        let scene = try AnnotationRealEventHarness(
                            windowState: windowState,
                            withMark: withMark,
                            insideAnalyzedSection: insideAnalyzedSection
                        )
                        defer { scene.teardown() }
                        let controller = scene.model.annotationController
                        controller.barVisible = true
                        controller.selectTool(tool)
                        let range = try scene.textDragRange()
                        #expect(
                            scene.hasMark(at: range.start) == withMark,
                            "\(label): the variant with a mark must really have it under the start of the drag"
                        )
                        #expect(scene.sectionIsAnalyzed == insideAnalyzedSection)

                        scene.drag(from: range.start, to: range.end)

                        let created = try #require(
                            controller.annotations.last(where: { $0.kind == kind }),
                            "\(label): the real drag must create the markup"
                        )
                        #expect(created.text?.isEmpty == false, "\(label): the selected text must be kept")
                        let native = try #require(
                            scene.ownedPDFAnnotation(id: created.id),
                            "\(label): the renderer must add the native PDFKit annotation"
                        )
                        expectQuadPointsAreAnnotationLocal(native, label: label)
                    }
                }
            }
        }
    }

    private func expectQuadPointsAreAnnotationLocal(_ annotation: PDFAnnotation, label: String) {
        let points = annotation.quadrilateralPoints ?? []
        #expect(points.count >= 4, "\(label): the markup must have at least one quadrilateral")
        let localBounds = CGRect(origin: .zero, size: annotation.bounds.size)
            .insetBy(dx: -0.5, dy: -0.5)
        for value in points {
            #expect(
                localBounds.contains(value.pointValue),
                "\(label): PDFKit wants quads relative to the annotation's origin, not page coordinates"
            )
        }
    }
}
}
