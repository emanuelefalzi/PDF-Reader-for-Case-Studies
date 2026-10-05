import SwiftUI

/// Compact map in the sidebar: computation is debounced and done off the
/// MainActor; the view shows at most 12 nodes plus the overflow.
struct MapSidebarView: View {
    @Environment(DocumentModel.self) private var model
    @State private var scene: MapScene?
    @State private var isComputing = false

    var body: some View {
        @Bindable var model = model
        let revision = MapViewRevision(
            data: model.mapDataRevision,
            page: model.currentPageIndex,
            scope: model.mapScope
        )

        VStack(spacing: 10) {
            Picker("Map scope", selection: $model.mapScope) {
                ForEach(MapScope.allCases, id: \.self) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)

            if let scene, !scene.fullGraph.nodes.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(scene.fullGraph.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DSColor.labelUppercase)
                        .lineLimit(1)
                    Spacer()
                    Text("\(scene.fullGraph.nodes.count) nodes")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DSColor.textTertiary)
                }
                .padding(.horizontal, 14)

                mapCard(scene)
            } else {
                emptyState
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: revision) { await rebuild(revision: revision) }
        .onDisappear { model.setHover(termId: nil) }
    }

    private func mapCard(_ scene: MapScene) -> some View {
        ZStack(alignment: .bottomTrailing) {
            MapCanvasView(
                graph: scene.displayedGraph,
                layout: scene.layout,
                interactiveViewport: false,
                zoom: .constant(1),
                pan: .constant(.zero),
                onHover: { model.setHover(termId: $0) },
                onSelect: select
            )

            HStack(spacing: 5) {
                Button {
                    model.openExpandedMap(initialZoom: 1.25)
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22)
                }
                .help("Open and enlarge the map")

                Button {
                    model.openExpandedMap()
                } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 5)
                        .frame(height: 22)
                }
                .help("Expand the map")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(8)
        }
        .frame(maxWidth: .infinity, minHeight: 250, maxHeight: 330)
        .background(Color.white.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DSColor.borderThumbnail, lineWidth: 0.5))
        .padding(.horizontal, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            if isComputing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 22))
                    .foregroundStyle(DSColor.textTertiary)
            }
            Text("Analyze a block to see the map")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DSColor.textSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func select(_ node: MapNode) {
        if node.isOverflow {
            model.openExpandedMap()
        } else {
            model.navigateToMapNode(node)
        }
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
            MapSceneBuilder.build(request, sidebarLimit: MapSidebarProjection.nodeLimit)
        }.value
        PerfProbe.record("map.build.await", elapsedMs: (CFAbsoluteTimeGetCurrent() - buildStart) * 1000)
        guard !Task.isCancelled else { return }
        scene = result
        isComputing = false
    }
}
