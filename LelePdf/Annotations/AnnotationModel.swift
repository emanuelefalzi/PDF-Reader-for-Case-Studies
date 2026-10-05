import Foundation

/// Kind of free annotation in the style of Preview (SPEC §8 v2.4): the same
/// literal list as the saved schema, never extended beyond what Preview
/// offers (SPEC §5.13 "Excluded: signature, crop, rotation, color
/// adjustment, loupe and mask").
enum AnnotationKind: String, Codable, Sendable, CaseIterable {
    case highlight, underline, strikeout, ink
    case rectangle, roundedRectangle, ellipse, line, arrow, speechBubble, star, polygon
    case textbox, note

    /// "Text" tools (SPEC §5.13): they act on the `PDFView`'s current text
    /// selection, not on a free gesture on the page.
    var isTextMarkup: Bool {
        switch self {
        case .highlight, .underline, .strikeout: true
        default: false
        }
    }

    /// Shapes PDFKit has no native subtype for (SPEC §5.13 "shapes
    /// Preview has but PDFKit lacks"): drawn by `ShapePDFAnnotation`
    /// instead of a native type (`.square`, `.circle`, `.line`).
    var needsCustomShapeAnnotation: Bool {
        switch self {
        case .roundedRectangle, .speechBubble, .star, .polygon: true
        default: false
        }
    }
}

/// Sendable/Codable color independent of `NSColor` (never `@MainActor`):
/// components 0...1, like `NSColor.usingColorSpace(.deviceRGB)`.
struct AnnotationColor: Codable, Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let clear = AnnotationColor(red: 0, green: 0, blue: 0, alpha: 0)
}

/// Point in PDF page space (points, not pixels, SPEC §5.13 "Coordinates").
struct AnnotationPoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}

/// Rectangle in PDF page space. Its own struct (not `CGRect`) so that it
/// stays unambiguously `Sendable`/`Codable` under Swift 6 strict
/// concurrency without depending on retroactive CoreGraphics conformances;
/// `AnnotationGeometry+CoreGraphics.swift` converts to/from `CGRect`.
struct AnnotationRect: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// Character range within the page (SPEC §8 `textRange?{start,length}`, same
/// convention as `MarkRange`: units of `Character` of the PDFKit page text
/// for that page).
struct AnnotationTextRange: Codable, Sendable, Equatable {
    var start: Int
    var length: Int
}

/// A saved annotation (SPEC §8 v2.4, `annotazioni.json`).
struct Annotation: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var page: Int
    var kind: AnnotationKind
    var color: AnnotationColor
    var fillColor: AnnotationColor?
    var lineWidth: Double?
    var dash: [Double]?
    /// Bounding box in page space: for shapes, the shape's frame; for the
    /// pen/polygon, the minimal box containing `points`; for text/note, the
    /// area of the box/icon.
    var rect: AnnotationRect
    var textRange: AnnotationTextRange?
    /// Per-line rectangles (SPEC §8 `quads?[]`), for highlight/underline/
    /// strikethrough over multi-line text.
    var quads: [AnnotationRect]?
    /// Pen points or polygon vertices, in page space.
    var points: [AnnotationPoint]?
    var text: String?
    var fontSize: Double?
    var font: String?
    var alignment: String?
    /// Stable identity of an annotation already in the PDF and created by
    /// another application (for example Preview). When set, LelePdf shows it
    /// and includes it in its own data, but does not add a second copy to the
    /// `PDFDocument`: the native original is already on the page.
    /// Optional to stay compatible with v1 `annotazioni.json` files.
    var externalPDFIdentifier: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String, page: Int, kind: AnnotationKind, color: AnnotationColor, fillColor: AnnotationColor? = nil,
        lineWidth: Double? = nil, dash: [Double]? = nil, rect: AnnotationRect, textRange: AnnotationTextRange? = nil,
        quads: [AnnotationRect]? = nil, points: [AnnotationPoint]? = nil, text: String? = nil, fontSize: Double? = nil,
        font: String? = nil, alignment: String? = nil, externalPDFIdentifier: String? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.page = page
        self.kind = kind
        self.color = color
        self.fillColor = fillColor
        self.lineWidth = lineWidth
        self.dash = dash
        self.rect = rect
        self.textRange = textRange
        self.quads = quads
        self.points = points
        self.text = text
        self.fontSize = fontSize
        self.font = font
        self.alignment = alignment
        self.externalPDFIdentifier = externalPDFIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// `annotazioni.json`, `version: 1` (SPEC §8 v2.4).
struct AnnotationsRecord: Codable, Sendable, Equatable {
    var version: Int = 1
    var items: [Annotation] = []
}

/// Sequential ids "a1", "a2", ... (same convention as `ManualMarks`).
enum AnnotationIdentifiers {
    static func nextId(in items: [Annotation]) -> String {
        let maxExisting = items.compactMap { item -> Int? in
            guard item.id.hasPrefix("a") else { return nil }
            return Int(item.id.dropFirst())
        }.max() ?? 0
        return "a\(maxExisting + 1)"
    }

    /// Generator of several new ids in sequence for ONE group of edits
    /// (Preview-style highlighter: splitting a mark in the middle
    /// creates a second piece with a new id, and a multi-page selection can
    /// create more than one in the same gesture). `nextId(in:)` alone is not
    /// enough because it looks at `items`, which does not yet reflect the
    /// annotations created later in the SAME group, not yet applied to the
    /// controller's state.
    static func sequentialIdGenerator(in items: [Annotation]) -> () -> String {
        var counter = items.compactMap { item -> Int? in
            guard item.id.hasPrefix("a") else { return nil }
            return Int(item.id.dropFirst())
        }.max() ?? 0
        return {
            counter += 1
            return "a\(counter)"
        }
    }
}
