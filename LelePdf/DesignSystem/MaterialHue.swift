import Foundation

/// SPEC §5.4 v2.6 "Color per subject" (decided 2026-09-16): the 4 marks no
/// longer have 4 different colors (they already differ by shape). Each
/// document has a single **hue**, chosen by the user, and all marks, map
/// nodes and marked terms in the rewrite use tone variations of that same
/// hue.
///
/// Pure (`Foundation` only): no dependency on AppKit/SwiftUI, so the
/// hue-to-tones formula and the contrast check are testable on their own
/// (`MaterialPaletteTests`) instead of once per framework.
/// `MarkPalette` (AppKit, `Reader`/`Rewrite`) and `DSColor.markColors`
/// (SwiftUI, `Sidebar`/`Map`/`BlockCardView`) both read from here: a single
/// source of truth for the values instead of 8 hues x 5 tones repeated in
/// the asset catalog.
enum MaterialHue: String, CaseIterable, Codable, Sendable, Identifiable {
    case blu, verde, viola, ambra, rosso, verdeAcqua, rosa, grafite

    var id: String { rawValue }

    /// Hue for a document with no `colorTheme` saved in `documento.json` and
    /// no preference in Settings (SPEC §5.4: "a default color for new
    /// documents").
    static let `default`: MaterialHue = .blu

    /// Name shown in the "Subject color" picker (sidebar, legend) and in
    /// Settings (default color).
    var label: String {
        switch self {
        case .blu: String(localized: "Blue")
        case .verde: String(localized: "Green")
        case .viola: String(localized: "Purple")
        case .ambra: String(localized: "Amber")
        case .rosso: String(localized: "Red")
        case .verdeAcqua: String(localized: "Teal")
        case .rosa: String(localized: "Pink")
        case .grafite: String(localized: "Graphite")
        }
    }

    /// Base HSB hue, in degrees (0-360). Values chosen to stay clearly
    /// distinguishable from one another on the color wheel (SPEC "at least
    /// 8 hues"; see `MaterialPaletteTests.huesAreDistinguishable`).
    var hueDegrees: Double {
        switch self {
        case .blu: 215
        case .verde: 150
        case .viola: 265
        case .ambra: 38
        case .rosso: 355
        case .verdeAcqua: 178
        case .rosa: 335
        case .grafite: 220
        }
    }

    /// HSB saturation (0-1). `grafite` is nearly gray on purpose (one of the
    /// 8 hues required by SPEC is explicitly neutral); the others share the
    /// same value, so no hue looks "stronger" than the others at the same
    /// tone.
    var saturation: Double {
        self == .grafite ? 0.10 : 0.58
    }
}

/// The brightness stops shared by every hue (SPEC "scale of 4-5 tones
/// from lightest to darkest"): a single formula instead of values picked
/// by eye for each of the 8 hues. Assignment to the 4 marks in
/// `MaterialMarkTones.assignment(for:)`.
enum MaterialTone: Int, CaseIterable, Comparable, Sendable {
    case t1 = 1, t2, t3, t4, t5

    static func < (lhs: MaterialTone, rhs: MaterialTone) -> Bool { lhs.rawValue < rhs.rawValue }

    /// HSB brightness (1 = lightest, toward white; 0 = darkest, toward
    /// black). Values chosen and verified with
    /// `MaterialPaletteTests.contrastSanity` (SPEC §5.4 "readable on a white
    /// background and over the PDF text in multiply mode"): for every hue,
    /// `t3` (rectangle border/underline) stays above the 3:1 required by
    /// WCAG 1.4.11 for non-text graphical elements, `t4`/`t5` (circle/arrow,
    /// also used as text color) above the 4.5:1 required for text.
    var brightness: Double {
        switch self {
        case .t1: 0.97
        case .t2: 0.83
        case .t3: 0.58
        case .t4: 0.42
        case .t5: 0.25
        }
    }

    /// Light tones are also less saturated: raising only the HSB brightness
    /// leaves colors such as red/purple too full for a background under the
    /// text. The hue does not change, but `t1` becomes a true light pastel;
    /// from `t3` on the subject's full saturation is kept.
    var saturationMultiplier: Double {
        switch self {
        case .t1: 0.25
        case .t2: 0.65
        case .t3, .t4, .t5: 1
        }
    }
}

/// Assignment of tones to the 4 marks (SPEC §5.4 v2.6): "rectangle = light
/// background with medium border; circle = medium-dark stroke; underline =
/// medium stroke; arrow = dark stroke with solid head". Text (map chip,
/// marked term in the rewrite) always uses the darkest tone, to stay
/// readable regardless of the mark. Previously each type had its own
/// "text" color paired with its own fixed color; now that there is a
/// single hue per document, readability matters more than distinguishing
/// the marks (which still relies on shape).
enum MaterialMarkTones {
    struct Assignment: Sendable, Equatable {
        var fill: MaterialTone
        var stroke: MaterialTone
        var text: MaterialTone
    }

    static func assignment(for type: MarkType) -> Assignment {
        switch type {
        case .rectangle: Assignment(fill: .t1, stroke: .t3, text: .t5)
        case .circle: Assignment(fill: .t1, stroke: .t4, text: .t5)
        case .underline: Assignment(fill: .t1, stroke: .t3, text: .t5)
        case .arrow: Assignment(fill: .t1, stroke: .t5, text: .t5)
        }
    }
}

/// Pure HSB-to-RGB conversion and contrast computation (WCAG formulas),
/// used only by the readability tests (`MaterialPaletteTests`): the real
/// drawing uses the native `NSColor(hue:saturation:brightness:)`/
/// `Color(hue:saturation:brightness:)` initializers, which apply the same
/// conversion. This pure version allows computing relative luminance
/// without a graphics host (AppKit/SwiftUI), in a file without those
/// dependencies.
enum MaterialColorMath {
    static func saturation(hue: MaterialHue, tone: MaterialTone) -> Double {
        hue.saturation * tone.saturationMultiplier
    }

    static func rgb(hueDegrees: Double, saturation: Double, brightness: Double) -> (r: Double, g: Double, b: Double) {
        let normalizedHue = (hueDegrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = brightness * saturation
        let x = c * (1 - abs(normalizedHue.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r1, g1, b1): (Double, Double, Double)
        switch normalizedHue {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (r1 + m, g1 + m, b1 + m)
    }

    /// Relative sRGB luminance (WCAG 2.x formula).
    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio between two relative luminances (1-21).
    static func contrastRatio(_ l1: Double, _ l2: Double) -> Double {
        let lighter = max(l1, l2), darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Convenience for tests: contrast of a hue/tone against a white
    /// background (SPEC "readable on a white background").
    static func contrastAgainstWhite(hueDegrees: Double, saturation: Double, brightness: Double) -> Double {
        let (r, g, b) = rgb(hueDegrees: hueDegrees, saturation: saturation, brightness: brightness)
        return contrastRatio(relativeLuminance(r: r, g: g, b: b), 1.0)
    }
}
