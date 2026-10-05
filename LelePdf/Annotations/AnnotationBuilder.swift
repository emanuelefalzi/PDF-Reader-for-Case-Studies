import AppKit
@preconcurrency import PDFKit

/// Builds the NATIVE `PDFAnnotation` matching a model `Annotation` (SPEC
/// §5.13 "the same engine as Preview"): a native PDFKit type for every type
/// PDFKit supports, `ShapePDFAnnotation` for those it does not (rounded
/// rectangle, speech bubble, star, polygon). Pure with respect to the model
/// (no state), but `@MainActor` because `PDFAnnotation` requires it (SPEC
/// §6.3 "PDFKit only on the MainActor").
@MainActor
enum AnnotationBuilder {
    static func makePDFAnnotation(for model: Annotation) -> PDFAnnotation {
        switch model.kind {
        case .highlight: textMarkup(.highlight, model: model)
        case .underline: textMarkup(.underline, model: model)
        case .strikeout: textMarkup(.strikeOut, model: model)
        case .ink: inkAnnotation(model)
        case .rectangle: boxAnnotation(.square, model: model)
        case .ellipse: boxAnnotation(.circle, model: model)
        case .line: lineAnnotation(model, arrow: false)
        case .arrow: lineAnnotation(model, arrow: true)
        case .textbox: freeTextAnnotation(model)
        case .note: noteAnnotation(model)
        case .roundedRectangle, .speechBubble, .star, .polygon: ShapePDFAnnotation(model: model)
        }
    }

    /// Version always serializable in the PDF standard. Shapes without a
    /// native PDF subtype are approximated with native annotations:
    /// rectangle for rounded/speech bubble, closed Ink stroke for star and
    /// polygon. This way Preview shows them without knowing LelePdf's
    /// private Swift classes.
    static func makePersistablePDFAnnotation(for model: Annotation) -> PDFAnnotation {
        switch model.kind {
        case .roundedRectangle, .speechBubble:
            return boxAnnotation(.square, model: model)
        case .star:
            return inkAnnotation(model, fallbackPoints: starPoints(in: model.rect.cgRect))
        case .polygon:
            return inkAnnotation(model, fallbackPoints: model.points?.map(\.cgPoint) ?? [])
        default:
            return makePDFAnnotation(for: model)
        }
    }

    private static func color(_ value: AnnotationColor) -> NSColor {
        NSColor(deviceRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }

    // MARK: - Text (highlight/underline/strikethrough, SPEC "drag over the text")

    private static func textMarkup(_ subtype: PDFAnnotationSubtype, model: Annotation) -> PDFAnnotation {
        let bounds = model.rect.cgRect
        let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        annotation.color = color(model.color)
        let quads = (model.quads ?? [model.rect]).flatMap { quad -> [NSValue] in
            // PDFKit requires points in ANNOTATION space, that is relative
            // to the origin of `bounds` (PDFAnnotationMarkup.h). They used to
            // be absolute page coordinates: the model and the Store were
            // right, but Highlight/Underline/Strikethrough were drawn
            // outside their own box and ended up invisible.
            let rect = quad.cgRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            return [
                NSValue(point: CGPoint(x: rect.minX, y: rect.maxY)),
                NSValue(point: CGPoint(x: rect.maxX, y: rect.maxY)),
                NSValue(point: CGPoint(x: rect.minX, y: rect.minY)),
                NSValue(point: CGPoint(x: rect.maxX, y: rect.minY)),
            ]
        }
        annotation.quadrilateralPoints = quads
        return annotation
    }

    // MARK: - Pen (SPEC "Freehand pen")

    private static func inkAnnotation(_ model: Annotation, fallbackPoints: [CGPoint]? = nil) -> PDFAnnotation {
        let bounds = model.rect.cgRect
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = color(model.color)
        let border = PDFBorder()
        border.lineWidth = model.lineWidth ?? AnnotationLineWidth.medium.rawValue
        annotation.border = border
        // Like the markup quads, Ink paths are also relative to the
        // annotation's origin (PDFAnnotationInk.h). The absolute coordinates
        // saved in the model stay absolute; they are converted only at the
        // PDFKit boundary.
        let points = (model.points?.map(\.cgPoint) ?? fallbackPoints ?? []).map {
            CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)
        }
        guard points.count > 1 else { return annotation }
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        if model.kind == .star || model.kind == .polygon { path.close() }
        annotation.add(path)
        return annotation
    }

    private static func starPoints(in rect: CGRect) -> [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.382
        return (0 ..< 10).map { index in
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = CGFloat(index) * .pi / 5 - .pi / 2
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    // MARK: - Rectangle/ellipse (SPEC "Shapes")

    private static func boxAnnotation(_ subtype: PDFAnnotationSubtype, model: Annotation) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: model.rect.cgRect, forType: subtype, withProperties: nil)
        annotation.color = color(model.color)
        if let fillColor = model.fillColor { annotation.interiorColor = color(fillColor) }
        let border = PDFBorder()
        border.lineWidth = model.lineWidth ?? AnnotationLineWidth.medium.rawValue
        if let dash = model.dash, !dash.isEmpty { border.dashPattern = dash.map { NSNumber(value: $0) } }
        annotation.border = border
        return annotation
    }

    // MARK: - Line/arrow (SPEC "line, arrow")

    private static func lineAnnotation(_ model: Annotation, arrow: Bool) -> PDFAnnotation {
        let bounds = model.rect.cgRect
        let annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
        annotation.color = color(model.color)
        if let points = model.points, points.count >= 2 {
            annotation.startPoint = CGPoint(
                x: points[0].x - bounds.minX, y: points[0].y - bounds.minY
            )
            annotation.endPoint = CGPoint(
                x: points[1].x - bounds.minX, y: points[1].y - bounds.minY
            )
        }
        annotation.startLineStyle = .none
        annotation.endLineStyle = arrow ? .closedArrow : .none
        let border = PDFBorder()
        border.lineWidth = model.lineWidth ?? AnnotationLineWidth.medium.rawValue
        annotation.border = border
        return annotation
    }

    // MARK: - Text box (SPEC "click on the page, type directly")

    private static func freeTextAnnotation(_ model: Annotation) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: model.rect.cgRect, forType: .freeText, withProperties: nil)
        annotation.contents = model.text ?? ""
        annotation.font = NSFont.systemFont(ofSize: model.fontSize ?? 13)
        annotation.fontColor = color(model.color)
        annotation.color = .clear
        return annotation
    }

    // MARK: - Note (SPEC "yellow sticky note")

    private static func noteAnnotation(_ model: Annotation) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: model.rect.cgRect, forType: .text, withProperties: nil)
        annotation.contents = model.text ?? ""
        annotation.color = color(model.color)
        annotation.iconType = .note
        return annotation
    }
}
