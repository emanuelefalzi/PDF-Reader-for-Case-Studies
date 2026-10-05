import Foundation

/// A heading detected per SPEC §7.3: font ≥1.15× the body, or a short bold
/// line followed by normal text, or numbering ("4.1", "Chapter 2"). `rect`
/// serves the debug overlay (SPEC §11).
struct Heading: Sendable, Equatable {
    let pageIndex: Int
    let lineIndex: Int
    let text: String
    /// 1-3, from the ranking of sizes above the body (SPEC §7.3).
    let level: Int
    let rect: PageRect
}

/// The stretch of clean text of a paragraph on a single page, with the
/// rectangles of the lines that make it up (for the overlay/margin bar, SPEC
/// §11) and the implicit map to the original indices (inside `text`, through
/// `IndexedChar.orig`).
struct ParagraphPagePart: Sendable, Equatable {
    let pageIndex: Int
    var text: IndexedText
    var lineRects: [PageRect]
}

/// A paragraph (SPEC §7.3): separated from the others by a vertical gap or
/// an indent; it continues onto the next page if the last line does not end
/// with final punctuation and the following page starts in lowercase.
/// `parts` has more than one element only in this continuation case.
struct Paragraph: Sendable, Equatable {
    var parts: [ParagraphPagePart]
    /// Path of the current section (active level 1..3 headings when the
    /// paragraph was read), for the rule "a block never crosses a section
    /// boundary" (SPEC §7.3).
    var sectionPath: [String]

    var pageStart: Int { parts.first?.pageIndex ?? 0 }
    var pageEnd: Int { parts.last?.pageIndex ?? 0 }

    var cleanText: String {
        parts.map { $0.text.string }.joined(separator: " ")
    }

    var wordCount: Int {
        parts.reduce(0) { $0 + $1.text.string.split(whereSeparator: \.isWhitespace).count }
    }
}

/// Exhibit/table/figure zone (SPEC §7.3): excluded from paragraphs and
/// blocks, it only generates a reference with a label and page.
struct ExhibitRef: Sendable, Equatable, Codable {
    let label: String
    let page: Int
}

/// Where a candidate for the generated contents comes from (SPEC §7.4).
enum TocCandidateSource: String, Sendable, Codable {
    case heading
    case runningHeader
}

/// A candidate for the generated contents (SPEC §7.4): headings found in
/// the structure plus chapter names derived from the repeated headers, read
/// before removing them. `followingWords` are the next ~20 words, the only
/// context Claude will receive to clean them up (M4).
struct TocCandidate: Sendable, Equatable, Codable {
    let title: String
    let page: Int
    let levelHint: Int
    let source: TocCandidateSource
    var followingWords: String = ""
}
