import AppKit
@preconcurrency import PDFKit

/// Shapes PDFKit has no native subtype for (SPEC §5.13 "rounded rectangle,
/// speech bubble, star, polygon"): a `PDFAnnotation` subclass that draws
/// itself (`draw(with:in:)`), the standard technique for a custom look in
/// PDFKit. The context arrives already in page space (the same space as
/// `bounds`/`points`, no extra transform). It uses a convenience subtype
/// (`"LelePdfShape"`) that exists only in memory: the PDF write service
/// converts these shapes into standard Square/Ink annotations before
/// writing them, because Preview does not know this subclass.
///
/// NOT `@MainActor`: `PDFAnnotation.draw(with:in:)` is not isolated (PDFKit
/// may draw off the main actor, for example for thumbnails), so this
/// subclass stays `nonisolated` like its superclass. Colors are stored as
/// `Double` components (`Sendable`), never as a stored `NSColor`, and are
/// rebuilt inside `draw(with:in:)`.
final class ShapePDFAnnotation: PDFAnnotation {
    private let kind: AnnotationKind
    private let strokeComponents: (Double, Double, Double, Double)
    private let fillComponents: (Double, Double, Double, Double)?
    private let strokeWidth: CGFloat
    private let dashPattern: [Double]?
    /// Vertices in page space (only for `.polygon`; the other shapes are
    /// drawn from `bounds` alone).
    private let polygonPoints: [CGPoint]?

    @MainActor
    init(model: Annotation) {
        kind = model.kind
        strokeComponents = (model.color.red, model.color.green, model.color.blue, model.color.alpha)
        if let fill = model.fillColor, fill.alpha > 0 {
            fillComponents = (fill.red, fill.green, fill.blue, fill.alpha)
        } else {
            fillComponents = nil
        }
        strokeWidth = model.lineWidth ?? AnnotationLineWidth.medium.rawValue
        dashPattern = model.dash
        polygonPoints = model.points?.map(\.cgPoint)
        super.init(bounds: model.rect.cgRect, forType: PDFAnnotationSubtype(rawValue: "LelePdfShape"), withProperties: nil)
        color = NSColor(deviceRed: model.color.red, green: model.color.green, blue: model.color.blue, alpha: model.color.alpha)
    }

    required init?(coder: NSCoder) {
        // Never deserialized: in the PDF, the write service replaces it with standard types.
        return nil
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let path = shapePath()
        context.saveGState()
        if let fillComponents {
            context.addPath(path)
            context.setFillColor(red: CGFloat(fillComponents.0), green: CGFloat(fillComponents.1), blue: CGFloat(fillComponents.2), alpha: CGFloat(fillComponents.3))
            context.fillPath()
        }
        context.addPath(path)
        context.setStrokeColor(red: CGFloat(strokeComponents.0), green: CGFloat(strokeComponents.1), blue: CGFloat(strokeComponents.2), alpha: CGFloat(strokeComponents.3))
        context.setLineWidth(strokeWidth)
        if let dashPattern, !dashPattern.isEmpty {
            context.setLineDash(phase: 0, lengths: dashPattern.map { CGFloat($0) })
        }
        context.strokePath()
        context.restoreGState()
    }

    private func shapePath() -> CGPath {
        switch kind {
        case .roundedRectangle: return Self.roundedRectPath(bounds)
        case .speechBubble: return Self.speechBubblePath(bounds)
        case .star: return Self.starPath(bounds)
        case .polygon: return Self.polygonPath(polygonPoints ?? [])
        default: return CGPath(rect: bounds, transform: nil)
        }
    }

    private static func roundedRectPath(_ rect: CGRect) -> CGPath {
        let radius = min(rect.width, rect.height) * 0.18
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Speech bubble (SPEC "speech bubble"): rounded body with a small tail
    /// at the bottom left, like Preview's speech bubble.
    private static func speechBubblePath(_ rect: CGRect) -> CGPath {
        let bodyHeight = rect.height * 0.8
        let body = CGRect(x: rect.minX, y: rect.maxY - bodyHeight, width: rect.width, height: bodyHeight)
        let radius = min(body.width, body.height) * 0.2
        let path = CGMutablePath()
        path.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
        let tailWidth = rect.width * 0.18
        let tailX = rect.minX + rect.width * 0.22
        path.move(to: CGPoint(x: tailX, y: body.minY))
        path.addLine(to: CGPoint(x: tailX - tailWidth * 0.3, y: rect.minY))
        path.addLine(to: CGPoint(x: tailX + tailWidth, y: body.minY))
        path.closeSubpath()
        return path
    }

    /// 5-pointed star inscribed in `rect` (SPEC "star").
    private static func starPath(_ rect: CGRect) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * 0.382
        let path = CGMutablePath()
        let points = 5
        for index in 0 ..< (points * 2) {
            let radius = index.isMultiple(of: 2) ? outerRadius : innerRadius
            let angle = (CGFloat(index) * .pi / CGFloat(points)) - .pi / 2
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func polygonPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}
