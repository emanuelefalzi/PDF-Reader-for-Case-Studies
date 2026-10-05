import Foundation

/// English labels and SF Symbols of the Annotate bar (SPEC §5.13 "same
/// labels as Preview"; the app interface is in English, so the labels
/// follow Preview.app's English localization). Where Preview has no direct
/// term (Freehand Pen, Eraser: not in classic Preview's vocabulary), the
/// SPEC's own word is used, noted as a deviation.
enum AnnotationToolbarLabels {
    /// `TB_ShowMarkupToolbar`/`TB_HideMarkupToolbar`.
    static let showBar = "Show Markup Toolbar"
    static let hideBar = "Hide Markup Toolbar"

    static func label(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: "Selection" // Localizable "Selection".
        case .highlight: "Highlight" // TOOLBAR_Highlight.
        case .underline: "Underline" // Localizable "Underline".
        case .strikeout: "Strikethrough" // Localizable "Strikethrough".
        case .ink: "Pen" // [deviation] not in classic Preview's vocabulary.
        case .rectangle: "Rectangle" // PVRectangleAnnotationType.
        case .roundedRectangle: "Rounded Rectangle" // [deviation] coined in the SPEC, §5.13.
        case .ellipse: "Oval" // PVOvalAnnotationType.
        case .line: "Line" // PVLineAnnotationType.
        case .arrow: "Arrow" // PVArrowAnnotationType.
        case .speechBubble: "Speech Bubble" // 912.title, MainMenu.
        case .star: "Star" // dtC-DM-848.title, MainMenu.
        case .polygon: "Polygon" // bq1-0Q-cJx.title, MainMenu.
        case .textbox: "Text Box" // SPEC §5.13 (Preview uses only "Text").
        case .note: "Note" // Note Tool.
        case .eraser: "Eraser" // [deviation] not in classic Preview.
        }
    }

    /// Equivalent SF Symbols (verified available in the SDK): all present
    /// since SF Symbols 4, macOS 26 includes them.
    static func symbol(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeout: "strikethrough"
        case .ink: "scribble"
        case .rectangle: "rectangle"
        case .roundedRectangle: "square.on.square"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .speechBubble: "bubble.left"
        case .star: "star"
        case .polygon: "hexagon"
        case .textbox: "textformat"
        case .note: "note.text"
        case .eraser: "eraser"
        }
    }

    static func label(for color: AnnotationPaletteColor) -> String {
        switch color {
        case .yellow: "Yellow" // TB_Yellow.
        case .green: "Green" // TB_Green.
        case .blue: "Blue" // TB_Blue.
        case .pink: "Pink" // TB_Pink.
        case .purple: "Purple" // TB_Purple.
        }
    }

    /// SPEC "new text box starts with the placeholder text 'Text'
    /// selected" — see also `AnnotationOverlayView+TextEditors`.
    static let markupToggleSymbol = "pencil.tip.crop.circle"
}
