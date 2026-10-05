import SwiftUI

/// Color tokens used by the reader window (SPEC §5.1, design
/// `DirezioneA-preview.html`). Dark mode is out of scope (SPEC §3): the
/// window surface values are literals. The accent comes from the asset
/// catalog; mark colors are computed from the subject's hue
/// (`MaterialHue`) and its tones.
enum DSColor {
    // MARK: - Backgrounds

    static let windowBackground = Color(rgb: 0xD9D9DE)
    static let sidebarBackground = Color(rgb: 0xECECF0).opacity(0.92)
    static let rightPanelBackground = Color(rgb: 0xFBFBFC).opacity(0.96)
    static let pageBarBackground = Color(rgb: 0xE2E2E7).opacity(0.8)
    static let cardBackground = Color.white
    static let pillBackground = Color.white.opacity(0.7)
    static let segmentedTrack = Color.black.opacity(0.055)
    static let segmentedSelected = Color.white

    // MARK: - Text

    static let textPrimary = Color(rgb: 0x1C1C1E)
    static let textSecondary = Color(rgb: 0x75757D)
    static let textTertiary = Color(rgb: 0x8B8B93)
    static let labelUppercase = Color(rgb: 0x6C6C74)

    // MARK: - Borders

    static let borderSoft = Color(rgb: 0xD3D3D9)
    static let borderCard = Color(rgb: 0xE2E2E7)
    static let borderStrong = Color(rgb: 0xC9C9D0)
    static let borderThumbnail = Color(rgb: 0xD8D8DE)

    // MARK: - Accent

    static let accent = Color("Accent")
    static let accentBackground = Color("AccentBg")
    static let accentBorder = Color("AccentBorder")
}

extension Color {
    /// Initializer from a `0xRRGGBB` hex literal, for design colors not yet
    /// in the asset catalog.
    init(rgb hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension DSColor {
    /// Colors of the 4 marks as SwiftUI `Color` (SPEC §5.4 v2.6 "Color per
    /// subject"): same hue/tones as `MarkPalette` (AppKit), used here for the
    /// sidebar legend (`App/Sidebar.swift`), the map
    /// (`Map/MapCanvasView.swift`) and the rewrite decorations
    /// (`Rewrite/BlockCardView.swift`).
    struct MarkColors {
        let fill: Color
        let stroke: Color
        let text: Color
    }

    static func markColor(hue: MaterialHue, tone: MaterialTone) -> Color {
        Color(
            hue: hue.hueDegrees / 360,
            saturation: MaterialColorMath.saturation(hue: hue, tone: tone),
            brightness: tone.brightness
        )
    }

    static func markColors(for type: MarkType, hue: MaterialHue) -> MarkColors {
        let assignment = MaterialMarkTones.assignment(for: type)
        return MarkColors(
            fill: markColor(hue: hue, tone: assignment.fill),
            stroke: markColor(hue: hue, tone: assignment.stroke),
            text: markColor(hue: hue, tone: assignment.text)
        )
    }
}
