import SwiftUI

/// Overlay above the reader and the right panel. The sidebar stays visible
/// so the scope can be changed; Esc and the X button close it.
struct MapExpandedView: View {
    @Environment(DocumentModel.self) private var model
    @State private var scene: MapScene?
    @State private var pan: CGSize = .zero
    @State private var isComputing = false

    var body: some View {
        let revision = MapViewRevision(
            data: model.mapDataRevision,
            page: model.currentPageIndex,
            scope: model.mapScope
        )

        ZStack {
            Color(rgb: 0xF4F4F7).opacity(0.98)
            if let scene, !scene.fullGraph.nodes.isEmpty {
                MapCanvasView(
                    graph: scene.fullGraph,
                    layout: scene.layout,
                    interactiveViewport: true,
                    zoom: Bindable(model).mapZoom,
                    pan: $pan,
                    onHover: { model.setHover(termId: $0) },
                    onSelect: { model.navigateToMapNode($0) }
                )
                .padding(.top, 52)
            } else {
                VStack(spacing: 8) {
                    if isComputing { ProgressView().controlSize(.small) }
                    Text("Analyze a block to see the map")
                        .font(.system(size: 13))
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
        }
        .overlay(alignment: .top) { toolbar }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DSColor.borderStrong, lineWidth: 0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(12)
        .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
        .task(id: revision) { await rebuild(revision: revision) }
        .onDisappear { model.setHover(termId: nil) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(scene?.fullGraph.title ?? model.mapScope.label)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if let count = scene?.fullGraph.nodes.count {
                Text("\(count) nodes")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textTertiary)
            }
            Spacer()
            Picker("Scope", selection: Bindable(model).mapScope) {
                ForEach(MapScope.allCases, id: \.self) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            Button { model.zoomOut() } label: { Image(systemName: "minus") }
                .help("Zoom out (⌘−)")
            Text("\(Int((model.mapZoom * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: 44)
            Button { model.zoomIn() } label: { Image(systemName: "plus") }
                .help("Zoom in (⌘+)")
            Button { model.zoomActualSize() } label: { Image(systemName: "1.magnifyingglass") }
                .help("Actual size (⌘0)")
            Divider().frame(height: 18)
            Button { model.closeExpandedMap() } label: { Image(systemName: "xmark") }
                .help("Close (Esc)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.white.opacity(0.88))
        .overlay(alignment: .bottom) { Rectangle().fill(DSColor.borderCard).frame(height: 0.5) }
    }

    private func rebuild(revision: MapViewRevision) async {
        isComputing = true
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        let request = PerfProbe.measure("map.capture") { MapGraphSource.capture(from: model, scope: revision.scope) }
        let buildStart = CFAbsoluteTimeGetCurrent()
        let result = await Task.detached(priority: .userInitiated) {
            MapSceneBuilder.build(request, sidebarLimit: nil)
        }.value
        PerfProbe.record("map.build.await", elapsedMs: (CFAbsoluteTimeGetCurrent() - buildStart) * 1000)
        guard !Task.isCancelled else { return }
        scene = result
        pan = .zero
        isComputing = false
    }
}
