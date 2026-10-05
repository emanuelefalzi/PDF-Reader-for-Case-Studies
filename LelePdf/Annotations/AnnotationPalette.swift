import Foundation

/// The 5 Preview colors (SPEC §5.13 "default yellow, green, blue, pink,
/// purple"), raw (RGB components 0...1), from which both `AnnotationColor`
/// (model) and `NSColor` (drawing) are built; see
/// `AnnotationPalette+AppKit.swift`. Values taken from the system colors
/// closest to those Preview uses for notes/highlights (`TB_Yellow` etc. in
/// `Localizable.loctable`).
enum AnnotationPaletteColor: String, CaseIterable, Sendable, Codable {
    case yellow, green, blue, pink, purple

    var rgb: (Double, Double, Double) {
        switch self {
        case .yellow: (1.0, 0.902, 0.259)
        case .green: (0.518, 0.882, 0.365)
        case .blue: (0.420, 0.741, 0.980)
        case .pink: (0.988, 0.635, 0.784)
        case .purple: (0.788, 0.635, 0.980)
        }
    }

    /// Opacity of the "multiply" highlighter (SPEC "look ... same as
    /// Preview"): full for the other tools, fainter only for the highlight
    /// (the text underneath must stay readable).
    func color(alpha: Double = 1) -> AnnotationColor {
        let (r, g, b) = rgb
        return AnnotationColor(red: r, green: g, blue: b, alpha: alpha)
    }

    static let highlightAlpha: Double = 0.55
}

/// Stroke width (SPEC "Freehand pen with 3 widths"; shapes and lines also
/// use the same three).
enum AnnotationLineWidth: Double, CaseIterable, Sendable, Codable {
    case thin = 1.5
    case medium = 3
    case thick = 5.5
}

/// Last color/width used for each tool (SPEC "the last one used for each
/// tool is remembered"): harmless interface preferences (a user setting
/// like the others already in `UserDefaults`, not saved analysis/annotation
/// data).
enum AnnotationToolMemory {
    private static let defaultsKeyPrefix = "annotationLastColor."
    private static let widthKeyPrefix = "annotationLastWidth."
    static var defaultStore: UserDefaults { AppRuntime.defaults }

    static func lastColor(for tool: AnnotationTool, defaults: UserDefaults = defaultStore) -> AnnotationPaletteColor {
        guard let raw = defaults.string(forKey: defaultsKeyPrefix + tool.rawValue),
              let color = AnnotationPaletteColor(rawValue: raw) else { return .yellow }
        return color
    }

    static func setLastColor(_ color: AnnotationPaletteColor, for tool: AnnotationTool, defaults: UserDefaults = defaultStore) {
        defaults.set(color.rawValue, forKey: defaultsKeyPrefix + tool.rawValue)
    }

    static func lastWidth(for tool: AnnotationTool, defaults: UserDefaults = defaultStore) -> AnnotationLineWidth {
        let raw = defaults.double(forKey: widthKeyPrefix + tool.rawValue)
        return AnnotationLineWidth(rawValue: raw) ?? .medium
    }

    static func setLastWidth(_ width: AnnotationLineWidth, for tool: AnnotationTool, defaults: UserDefaults = defaultStore) {
        defaults.set(width.rawValue, forKey: widthKeyPrefix + tool.rawValue)
    }
}

/// Active tool in the Annotate bar (SPEC §5.13): not 1:1 with
/// `AnnotationKind` (Highlight/Shapes are a single button with several
/// outcomes).
enum AnnotationTool: String, CaseIterable, Sendable, Codable {
    case select, highlight, underline, strikeout, ink, eraser
    case rectangle, roundedRectangle, ellipse, line, arrow, speechBubble, star, polygon
    case textbox, note

    /// True for the "text" tools (SPEC): the page does not capture the drag,
    /// the native `PDFView` selection does (see `AnnotationOverlayView`).
    var isTextMarkup: Bool {
        switch self {
        case .highlight, .underline, .strikeout: true
        default: false
        }
    }

    var kind: AnnotationKind? {
        switch self {
        case .select, .eraser: nil
        case .highlight: .highlight
        case .underline: .underline
        case .strikeout: .strikeout
        case .ink: .ink
        case .rectangle: .rectangle
        case .roundedRectangle: .roundedRectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .speechBubble: .speechBubble
        case .star: .star
        case .polygon: .polygon
        case .textbox: .textbox
        case .note: .note
        }
    }
}
