import SwiftUI

extension AnnotationPaletteColor {
    /// SwiftUI color for the Annotate bar's dots (SPEC "default colors ...
    /// same as Preview").
    var swiftUIColor: Color {
        let (r, g, b) = rgb
        return Color(red: r, green: g, blue: b)
    }
}

/// 5 color dots (SPEC "Colors and widths: the last one used for each tool
/// is remembered"): they apply the color immediately to the selected
/// annotation if there is one, otherwise they become the color of the next
/// gesture with the active tool.
struct AnnotationColorSwatches: View {
    let controller: AnnotationController

    var body: some View {
        HStack(spacing: 5) {
            ForEach(AnnotationPaletteColor.allCases, id: \.self) { color in
                Button {
                    apply(color)
                } label: {
                    Circle()
                        .fill(color.swiftUIColor)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(DSColor.borderStrong, lineWidth: controller.currentColor == color ? 1.5 : 0.5))
                }
                .buttonStyle(.plain)
                .help(AnnotationToolbarLabels.label(for: color))
            }
        }
    }

    private func apply(_ color: AnnotationPaletteColor) {
        controller.currentColor = color
        guard let id = controller.selectedId else { return }
        let alpha = controller.tool == .highlight ? AnnotationPaletteColor.highlightAlpha : 1
        controller.update(id: id, actionName: "Change Color") { $0.color = color.color(alpha: alpha) }
    }
}

/// 3 widths (SPEC "Pen ... 3 widths"; also shapes and lines).
struct AnnotationWidthPicker: View {
    let controller: AnnotationController

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationLineWidth.allCases, id: \.self) { width in
                Button {
                    apply(width)
                } label: {
                    Circle()
                        .fill(controller.currentWidth == width ? DSColor.accent : DSColor.textTertiary)
                        .frame(width: dotSize(width), height: dotSize(width))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func dotSize(_ width: AnnotationLineWidth) -> CGFloat {
        switch width {
        case .thin: 5
        case .medium: 8
        case .thick: 11
        }
    }

    private func apply(_ width: AnnotationLineWidth) {
        controller.currentWidth = width
        guard let id = controller.selectedId else { return }
        controller.update(id: id, actionName: "Change Thickness") { $0.lineWidth = width.rawValue }
    }
}
