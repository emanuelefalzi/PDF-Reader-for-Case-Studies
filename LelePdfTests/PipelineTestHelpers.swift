import Foundation
@testable import LelePdf

/// Factories for synthetic lines/pages, used by the text pipeline unit tests
/// (SPEC §7, §11 row M2): no PDFKit, only the `Sendable` models that the pure
/// pipeline consumes.
enum PipelineFixtures {
    static func extractedLine(
        text: String,
        location: Int,
        rect: PageRect,
        fontSize: CGFloat = 12,
        isBold: Bool = false,
        superscriptRanges: [CharRange] = []
    ) -> ExtractedLine {
        ExtractedLine(
            text: text,
            charRange: CharRange(location: location, length: text.count),
            rect: rect,
            fontSize: fontSize,
            isBold: isBold,
            superscriptRanges: superscriptRanges
        )
    }

    static func indexedText(_ text: String, startingAt orig: Int = 0) -> IndexedText {
        text.enumerated().map { IndexedChar(ch: $0.element, orig: orig + $0.offset) }
    }

    static func cleanLine(
        page: Int = 0,
        lineIndex: Int,
        text: String,
        y: CGFloat,
        fontSize: CGFloat = 12,
        isBold: Bool = false
    ) -> CleanLine {
        CleanLine(
            pageIndex: page,
            lineIndex: lineIndex,
            text: indexedText(text, startingAt: lineIndex * 1000),
            rect: PageRect(x: 72, y: y, width: 400, height: fontSize + 2),
            fontSize: fontSize,
            isBold: isBold
        )
    }

    static func paragraph(page: Int, text: String, sectionPath: [String] = []) -> Paragraph {
        Paragraph(
            parts: [ParagraphPagePart(pageIndex: page, text: indexedText(text), lineRects: [])],
            sectionPath: sectionPath
        )
    }

    static func words(_ count: Int, prefix: String = "word") -> String {
        (0 ..< count).map { "\(prefix)\($0)" }.joined(separator: " ") + "."
    }
}
