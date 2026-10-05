import SwiftUI

struct MapCanvasTransform: Sendable, Equatable {
    var scale: Double
    var offset: MapPoint

    static func fitted(layout: ConceptMapLayout, viewport: CGSize, zoom: Double, pan: CGSize) -> MapCanvasTransform {
        let availableWidth = max(1, Double(viewport.width) - 24)
        let availableHeight = max(1, Double(viewport.height) - 24)
        let fittedScale = min(availableWidth / layout.contentSize.width, availableHeight / layout.contentSize.height, 1)
        let scale = max(0.05, fittedScale * zoom)
        let renderedWidth = layout.contentSize.width * scale
        let renderedHeight = layout.contentSize.height * scale
        return MapCanvasTransform(
            scale: scale,
            offset: MapPoint(
                x: (Double(viewport.width) - renderedWidth) / 2 + Double(pan.width),
                y: (Double(viewport.height) - renderedHeight) / 2 + Double(pan.height)
            )
        )
    }

    func mapPoint(fromView point: CGPoint) -> MapPoint {
        MapPoint(x: (Double(point.x) - offset.x) / scale, y: (Double(point.y) - offset.y) / scale)
    }
}

/// Single drawing for the preview and the expanded overlay. AppKit
/// interaction is in a separate layer so it also receives the scroll wheel/
/// trackpad and magnify events.
struct MapCanvasView: View {
    let graph: ConceptMapGraph
    let layout: ConceptMapLayout
    let interactiveViewport: Bool
    @Binding var zoom: Double
    @Binding var pan: CGSize
    let onHover: (String?) -> Void
    let onSelect: (MapNode) -> Void

    @Environment(DocumentModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            let transform = MapCanvasTransform.fitted(
                layout: layout, viewport: geometry.size,
                zoom: interactiveViewport ? zoom : 1,
                pan: interactiveViewport ? pan : .zero
            )
            Canvas { context, _ in
                context.translateBy(x: transform.offset.x, y: transform.offset.y)
                context.scaleBy(x: transform.scale, y: transform.scale)
                drawGroups(context: &context)
                drawEdges(context: &context)
                drawNodes(context: &context)
            }
            .overlay {
                MapInteractionLayer(
                    graph: graph,
                    layout: layout,
                    transform: transform,
                    enablesViewportGestures: interactiveViewport,
                    onHover: onHover,
                    onSelect: onSelect,
                    onPan: { delta in
                        pan.width += delta.width
                        pan.height += delta.height
                    },
                    onZoom: { factor in
                        zoom = min(3.5, max(0.45, zoom * factor))
                    }
                )
            }
        }
    }

    private func drawGroups(context: inout GraphicsContext) {
        for group in layout.groupFrames {
            let rect = cgRect(group.rect)
            let path = Path(roundedRect: rect, cornerRadius: 18)
            context.fill(path, with: .color(Color.white.opacity(0.48)))
            context.stroke(path, with: .color(DSColor.borderStrong.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            context.draw(
                Text(group.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DSColor.labelUppercase),
                at: CGPoint(x: rect.minX + 14, y: rect.minY + 15), anchor: .leading
            )
        }
    }

    private func drawEdges(context: inout GraphicsContext) {
        // SPEC §5.4 v2.6 "Color by subject": the map's arrows/underlines no
        // longer have a color of their own, they are tones of the document's
        // own hue (`model.colorTheme`), read here, inside `body` (through
        // `drawGroups`/`drawEdges`/`drawNodes`, called by `Canvas` in
        // `body`), so a hue change redraws the map on its own
        // (`@Observable`, no AppKit view in between).
        let hue = model.colorTheme
        let arrowColor = DSColor.markColors(for: .arrow, hue: hue).stroke
        let underlineColor = DSColor.markColors(for: .underline, hue: hue).stroke
        let arrowTextColor = DSColor.markColors(for: .arrow, hue: hue).text
        let underlineTextColor = DSColor.markColors(for: .underline, hue: hue).text
        let labelFrames = Dictionary(uniqueKeysWithValues: layout.edgeLabelFrames.map { ($0.edgeID, $0) })
        for edge in graph.edges {
            guard let sourceRect = layout.frame(for: edge.from), let targetRect = layout.frame(for: edge.to) else { continue }
            let start = MapGeometry.boundaryPoint(of: sourceRect, toward: targetRect.center)
            let end = MapGeometry.boundaryPoint(of: targetRect, toward: sourceRect.center)
            var path = Path()
            path.move(to: cgPoint(start))
            path.addLine(to: cgPoint(end))
            let color = edge.kind == .effect ? arrowColor : underlineColor
            context.stroke(path, with: .color(color.opacity(0.82)), lineWidth: edge.source == .manual ? 1.9 : 1.35)
            if edge.kind == .effect { drawArrowhead(context: &context, start: start, end: end, color: color) }
            // Only the labels that `MapEdgeLabelLayout` has already placed
            // without overlaps are drawn (SPEC §7.7): the others stay
            // without a label instead of overlapping a node or another
            // label.
            if let frame = labelFrames[edge.id] {
                drawEdgeLabel(context: &context, frame: frame, color: edge.kind == .effect ? arrowTextColor : underlineTextColor)
            }
        }
    }

    private func drawNodes(context: inout GraphicsContext) {
        let hue = model.colorTheme
        let circleColors = DSColor.markColors(for: .circle, hue: hue)
        let rectColors = DSColor.markColors(for: .rectangle, hue: hue)
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        for frame in layout.nodeFrames {
            guard let node = nodes[frame.nodeID] else { continue }
            let rect = cgRect(frame.rect)
            let hovered = model.hoveredTermId == node.id
            let lineWidth = hovered ? 2.4 : 1.15
            if node.isOverflow {
                let path = Path(roundedRect: rect, cornerRadius: 9)
                context.fill(path, with: .color(Color.white.opacity(0.82)))
                context.stroke(path, with: .color(DSColor.borderStrong), style: StrokeStyle(lineWidth: lineWidth, dash: [5, 3]))
            } else if node.shape == .ellipse {
                let path = Path(ellipseIn: rect)
                context.fill(path, with: .color(Color.white.opacity(hovered ? 0.98 : 0.84)))
                context.stroke(path, with: .color(circleColors.stroke.opacity(hovered ? 1 : 0.86)), lineWidth: lineWidth)
            } else {
                let path = Path(roundedRect: rect, cornerRadius: 10)
                context.fill(path, with: .color(rectColors.fill.opacity(hovered ? 1 : 0.9)))
                context.stroke(path, with: .color(rectColors.stroke), lineWidth: lineWidth)
            }
            let textColor = node.isOverflow ? DSColor.textSecondary :
                (node.shape == .ellipse ? circleColors.text : rectColors.text)
            context.draw(
                Text(MapLabelWrapping.wrapped(node.label))
                    .font(.system(size: 12, weight: hovered ? .bold : .semibold))
                    .foregroundStyle(textColor),
                at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center
            )
        }
    }

    private func drawEdgeLabel(context: inout GraphicsContext, frame: MapEdgeLabelFrame, color: Color) {
        let rect = cgRect(frame.rect)
        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Color.white.opacity(0.9)))
        context.draw(
            Text(frame.text).font(.system(size: 9.5)).foregroundStyle(color),
            at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center
        )
    }

    private func drawArrowhead(context: inout GraphicsContext, start: MapPoint, end: MapPoint, color: Color) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(0.001, hypot(dx, dy))
        let ux = dx / length, uy = dy / length
        let baseX = end.x - ux * 10, baseY = end.y - uy * 10
        var path = Path()
        path.move(to: cgPoint(end))
        path.addLine(to: CGPoint(x: baseX - uy * 4.5, y: baseY + ux * 4.5))
        path.addLine(to: CGPoint(x: baseX + uy * 4.5, y: baseY - ux * 4.5))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    private func cgRect(_ rect: MapRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private func cgPoint(_ point: MapPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }
}
