import AppKit
@preconcurrency import PDFKit

/// The four marks resolved into page coordinates, ready to be inserted into
/// the PDF without depending on `TextBlock`/`PDFSelection` during the
/// atomic write phase.
struct PDFMarkSnapshot: Sendable, Equatable {
    var id: String
    var page: Int
    var type: MarkType
    var text: String
    var lineRects: [AnnotationRect]
}

/// Explicit translation of the four marks into standard PDF subtypes:
/// concept → Highlight, actor/number → Square, action → Underline,
/// consequence → Text note. All are editable and visible in Preview without
/// a LelePdf renderer.
@MainActor
enum PDFMarkAnnotationBuilder {
    static func make(_ mark: PDFMarkSnapshot, hue: MaterialHue) -> PDFAnnotation? {
        guard let first = mark.lineRects.first else { return nil }
        let rect = mark.lineRects.dropFirst().reduce(first.cgRect) { $0.union($1.cgRect) }
        let annotation: PDFAnnotation
        switch mark.type {
        case .rectangle:
            annotation = textMarkup(.highlight, mark: mark, bounds: rect)
        case .circle:
            annotation = PDFAnnotation(bounds: rect.insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = 2
            annotation.border = border
        case .underline:
            annotation = textMarkup(.underline, mark: mark, bounds: rect)
        case .arrow:
            let size: CGFloat = 22
            let noteRect = CGRect(x: rect.maxX + 2, y: rect.midY - size / 2, width: size, height: size)
            annotation = PDFAnnotation(bounds: noteRect, forType: .text, withProperties: nil)
            annotation.contents = mark.text
            annotation.iconType = .note
        }
        annotation.color = color(for: mark.type, hue: hue)
        PDFAnnotationOwnership.tag(annotation, role: .mark, id: mark.id)
        return annotation
    }

    static func color(for type: MarkType, hue: MaterialHue) -> NSColor {
        let assignment = MaterialMarkTones.assignment(for: type)
        let base = MarkPalette.nsColor(hue: hue, tone: assignment.stroke)
        return type == .rectangle ? base.withAlphaComponent(0.42) : base
    }

    private static func textMarkup(
        _ subtype: PDFAnnotationSubtype, mark: PDFMarkSnapshot, bounds: CGRect
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        annotation.quadrilateralPoints = mark.lineRects.flatMap { item -> [NSValue] in
            let rect = item.cgRect
            return [
                NSValue(point: CGPoint(x: rect.minX, y: rect.maxY)),
                NSValue(point: CGPoint(x: rect.maxX, y: rect.maxY)),
                NSValue(point: CGPoint(x: rect.minX, y: rect.minY)),
                NSValue(point: CGPoint(x: rect.maxX, y: rect.minY)),
            ]
        }
        return annotation
    }
}
