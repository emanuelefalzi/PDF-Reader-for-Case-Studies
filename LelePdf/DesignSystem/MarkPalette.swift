import AppKit

/// Colors of the 4 marks as `NSColor` (SPEC §5.4 v2.6 "Color per subject"):
/// tones of a single hue per document (`MaterialHue`), no longer a fixed
/// color per mark type. One source of truth for the values
/// (`MaterialHue`/`MaterialTone`/`MaterialMarkTones`, `DesignSystem/
/// MaterialHue.swift`, pure), two representations because the PDF overlay
/// and `MarkedTextView` draw with AppKit (`Reader/
/// MarksOverlayDrawing.swift`, `Rewrite/MarkedNSTextView.swift`) while the
/// rest of the UI (legend, map) uses SwiftUI (`DSColor.
/// markColors`).
enum MarkPalette {
    struct Colors {
        let fill: NSColor
        let stroke: NSColor
        let text: NSColor
    }

    static func colors(for type: MarkType, hue: MaterialHue) -> Colors {
        let assignment = MaterialMarkTones.assignment(for: type)
        // Only the rectangle has a solid fill (SPEC "rectangle = light
        // background"): the other 3 marks stay stroke-only with no background,
        // as before v2.6.
        let fill = type == .rectangle ? nsColor(hue: hue, tone: assignment.fill) : .clear
        return Colors(fill: fill, stroke: nsColor(hue: hue, tone: assignment.stroke), text: nsColor(hue: hue, tone: assignment.text))
    }

    static func nsColor(hue: MaterialHue, tone: MaterialTone) -> NSColor {
        NSColor(
            hue: hue.hueDegrees / 360,
            saturation: MaterialColorMath.saturation(hue: hue, tone: tone),
            brightness: tone.brightness,
            alpha: 1
        )
    }
}

extension NSColor {
    /// Hover/linked emphasis on the same hue (SPEC §5.4): darker and more
    /// saturated, so truly "more vivid", without shifting the hue angle. The
    /// name is the historical one used by the three renderers.
    func darkened(by fraction: CGFloat) -> NSColor {
        guard fraction > 0 else { return self }
        let converted = usingColorSpace(.deviceRGB) ?? self
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let amount = min(1, fraction)
        let vividSaturation = min(1, saturation + amount * 0.35 * (1 - saturation))
        return NSColor(
            deviceHue: hue,
            saturation: vividSaturation,
            brightness: brightness * (1 - amount),
            alpha: alpha
        )
    }
}
