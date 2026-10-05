import SwiftUI
import UniformTypeIdentifiers

/// Window body below the toolbar: sidebar, PDF, right panel (SPEC §5.1).
/// An `HStack` with widths computed by `WindowLayoutMath` instead of
/// `NavigationSplitView`, to control precisely the constraints 264 / 440
/// minimum / 320-520.
struct ThreePaneLayout: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            let layout = WindowLayoutMath.compute(
                totalWidth: geometry.size.width,
                sidebarVisible: model.sidebarVisible,
                rightPanelVisible: model.rightPanelVisible,
                preferredSidebarWidth: model.sidebarWidth,
                preferredRightPanelWidth: model.rightPanelWidth
            )

            ZStack {
                let _ = PerfProbe.hit("swiftui.ThreePaneLayout.body")
                HStack(spacing: 0) {
                    if layout.sidebarWidth > 0 {
                        Sidebar()
                            .frame(width: layout.sidebarWidth)
                        // Previously the sidebar had no draggable divider, it was fixed at
                        // 264 pt.
                        PaneDivider(
                            width: Bindable(model).sidebarWidth,
                            range: DSMetrics.sidebarMinWidth...DSMetrics.sidebarMaxWidth,
                            defaultWidth: DSMetrics.sidebarWidth,
                            growsWithPositiveTranslation: true
                        )
                    }

                    ZStack {
                        HStack(spacing: 0) {
                            ReaderPane()
                                .frame(minWidth: DSMetrics.minCenterWidth)
                                .layoutPriority(1)

                            if layout.rightPanelWidth > 0 {
                                PaneDivider(
                                    width: Bindable(model).rightPanelWidth,
                                    range: DSMetrics.rightPanelMinWidth...DSMetrics.rightPanelMaxWidth,
                                    defaultWidth: DSMetrics.rightPanelDefaultWidth,
                                    growsWithPositiveTranslation: false,
                                    // See `PaneDivider.onDragging`. Only here, not on the sidebar's
                                    // divider: there the right panel does not change width (measured
                                    // 14.6 ms per event, within budget) and the PDF can keep
                                    // re-fitting live.
                                    onDragging: { dragging in
                                        if dragging { model.windowResizeCoalescer.begin() } else { model.windowResizeCoalescer.end() }
                                    }
                                )
                                RightPanel()
                                    .frame(width: layout.rightPanelWidth)
                            }
                        }

                        if model.mapExpanded {
                            MapExpandedView()
                                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                        }
                    }
                }
                ChatOverlay()
            }
            .animation(.easeInOut(duration: 0.18), value: layout)
            .animation(.easeInOut(duration: 0.16), value: model.mapExpanded)
        }
        .onDrop(of: [.pdf], isTargeted: nil, perform: handleDrop)
        .onExitCommand {
            // Esc: first the chat (in the foreground above everything, SPEC §5.9),
            // then the expanded map (SPEC M8), never both together, the chat wins.
            if model.chatController.isPresented {
                model.chatController.closePanel()
            } else if model.mapExpanded {
                model.closeExpandedMap()
            }
        }
    }

    // (WindowLayoutMath.Result is already Equatable: see WindowLayoutMath.swift.)

    /// Dragging a PDF onto the window opens it (SPEC §5.2); the Dock already
    /// provides that for free through `DocumentGroup`.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }
        return true
    }
}
