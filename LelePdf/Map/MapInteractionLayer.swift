import AppKit
import SwiftUI

/// Transparent layer above the Canvas. AppKit is needed here because
/// SwiftUI does not directly expose the scroll wheel events: mouse, drag,
/// scroll and pinch all stay available in the expanded map.
struct MapInteractionLayer: NSViewRepresentable {
    let graph: ConceptMapGraph
    let layout: ConceptMapLayout
    let transform: MapCanvasTransform
    let enablesViewportGestures: Bool
    let onHover: (String?) -> Void
    let onSelect: (MapNode) -> Void
    let onPan: (CGSize) -> Void
    let onZoom: (Double) -> Void

    func makeNSView(context: Context) -> MapInteractionNSView {
        MapInteractionNSView()
    }

    func updateNSView(_ view: MapInteractionNSView, context: Context) {
        view.graph = graph
        view.layout = layout
        view.transform = transform
        view.enablesViewportGestures = enablesViewportGestures
        view.onHover = onHover
        view.onSelect = onSelect
        view.onPan = onPan
        view.onZoom = onZoom
    }
}

@MainActor
final class MapInteractionNSView: NSView {
    var graph = ConceptMapGraph.empty(scope: .chapter)
    var layout = ConceptMapLayout.empty
    var transform = MapCanvasTransform(scale: 1, offset: MapPoint(x: 0, y: 0))
    var enablesViewportGestures = false
    var onHover: ((String?) -> Void)?
    var onSelect: ((MapNode) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onZoom: ((Double) -> Void)?

    private var tracking: NSTrackingArea?
    private var mouseDownPoint: CGPoint?
    private var previousDragPoint: CGPoint?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(nodeID(at: event))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        previousDragPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard enablesViewportGestures, let previousDragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        onPan?(CGSize(width: point.x - previousDragPoint.x, height: point.y - previousDragPoint.y))
        self.previousDragPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            previousDragPoint = nil
        }
        let point = convert(event.locationInWindow, from: nil)
        if let start = mouseDownPoint, hypot(point.x - start.x, point.y - start.y) > 4 { return }
        guard let id = nodeID(at: event), let node = graph.nodes.first(where: { $0.id == id }) else { return }
        onSelect?(node)
    }

    override func scrollWheel(with event: NSEvent) {
        guard enablesViewportGestures else {
            super.scrollWheel(with: event)
            return
        }
        onPan?(CGSize(width: -event.scrollingDeltaX, height: -event.scrollingDeltaY))
    }

    override func magnify(with event: NSEvent) {
        guard enablesViewportGestures else {
            super.magnify(with: event)
            return
        }
        onZoom?(max(0.2, 1 + Double(event.magnification)))
    }

    private func nodeID(at event: NSEvent) -> String? {
        let point = convert(event.locationInWindow, from: nil)
        return MapHitTesting.node(at: transform.mapPoint(fromView: point), in: layout)
    }
}
