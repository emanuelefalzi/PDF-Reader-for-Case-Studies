import SwiftUI

/// "Annotate" bar under the toolbar (SPEC §5.13): same tools, labels and
/// order as Preview (`AnnotationToolbarLabels`). The Highlight button and
/// the Shapes menu are `Menu(...,primaryAction:)` (SwiftUI): a click picks
/// the tool with the last remembered color/kind, the small dropdown picks
/// the color/shape, as in Preview.
struct AnnotationToolbarBar: View {
    @Environment(DocumentModel.self) private var model
    private var controller: AnnotationController { model.annotationController }

    private static let shapeTools: [AnnotationTool] = [.rectangle, .roundedRectangle, .ellipse, .line, .arrow, .speechBubble, .star, .polygon]

    var body: some View {
        HStack(spacing: 10) {
            toolButton(.select)
            Divider().frame(height: 18)

            Menu {
                ForEach(AnnotationPaletteColor.allCases, id: \.self) { color in
                    Button(AnnotationToolbarLabels.label(for: color)) { selectHighlight(color: color) }
                }
                Divider()
                Button(AnnotationToolbarLabels.label(for: .underline)) { controller.selectTool(.underline) }
                Button(AnnotationToolbarLabels.label(for: .strikeout)) { controller.selectTool(.strikeout) }
            } label: {
                toolLabel(.highlight)
            } primaryAction: {
                controller.selectTool(.highlight)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            toolButton(.ink)

            Menu {
                ForEach(Self.shapeTools, id: \.self) { tool in
                    Button(AnnotationToolbarLabels.label(for: tool)) { controller.selectTool(tool) }
                }
            } label: {
                toolLabel(Self.shapeTools.contains(controller.tool) ? controller.tool : .rectangle)
            } primaryAction: {
                controller.selectTool(Self.shapeTools.contains(controller.tool) ? controller.tool : .rectangle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            toolButton(.textbox)
            toolButton(.note)
            Divider().frame(height: 18)
            toolButton(.eraser)

            Divider().frame(height: 18)
            AnnotationColorSwatches(controller: controller)
            if showsWidthPicker { AnnotationWidthPicker(controller: controller) }

            Spacer()

            if controller.selectedId != nil {
                Button { controller.deleteSelected() } label: { Image(systemName: "trash") }
                    .help("Delete (⌫)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: DSMetrics.pageZoomBarHeight)
        .background(DSColor.pageBarBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(DSColor.borderSoft).frame(height: 0.5) }
    }

    private var showsWidthPicker: Bool {
        [.ink, .rectangle, .roundedRectangle, .ellipse, .line, .arrow, .speechBubble, .star, .polygon].contains(controller.tool)
    }

    private func selectHighlight(color: AnnotationPaletteColor) {
        controller.selectTool(.highlight)
        controller.currentColor = color
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button {
            controller.selectTool(tool)
        } label: {
            toolLabel(tool)
        }
        .buttonStyle(.plain)
    }

    private func toolLabel(_ tool: AnnotationTool) -> some View {
        Image(systemName: AnnotationToolbarLabels.symbol(for: tool))
            .font(.system(size: 14))
            .frame(width: 24, height: 24)
            .foregroundStyle(controller.tool == tool ? Color.white : DSColor.textPrimary)
            .background(controller.tool == tool ? DSColor.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .help(AnnotationToolbarLabels.label(for: tool))
    }
}
