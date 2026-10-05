import Foundation

/// Rectangle in page space (PDF, origin at the bottom left). `CGRect` is
/// already Codable: the alias only serves to make the reference space clear
/// in the pipeline's models (SPEC §7.1).
typealias PageRect = CGRect

/// Codable character range (`NSRange` is not), always in units of
/// `Character`/UTF-16 of `page.string`, the same unit used by
/// `PDFPage.selection(for:)` and `characterBounds(at:)`.
struct CharRange: Sendable, Codable, Hashable {
    let location: Int
    let length: Int

    var nsRange: NSRange { NSRange(location: location, length: length) }
    var upperBound: Int { location + length }

    init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    init(_ range: NSRange) {
        location = range.location
        length = range.length
    }
}

/// A line extracted from a page (SPEC §7.1): exact text (a substring of
/// `page.string`), rectangle in page space, the line's dominant font, and
/// any superscript digits to remove during cleaning (SPEC §7.2.4).
struct ExtractedLine: Sendable, Codable, Equatable {
    let text: String
    let charRange: CharRange
    let rect: PageRect
    let fontSize: CGFloat
    let isBold: Bool
    /// Ranges (in `page.string`) of digits with a font smaller than the
    /// line's dominant body: footnote numbers attached to the text
    /// ("returns.20", Merck case).
    let superscriptRanges: [CharRange]
    /// Original index in `page.string` of each character of `text`, in the
    /// same order (to handle doubled letters from simulated bold/OCR,
    /// "Buuildingg the Teeam"). Normally `charOrigins[i] ==
    /// charRange.location + i` (a contiguous map): `LineExtractor` always
    /// fills it in, but the map becomes NON-contiguous when
    /// `DuplicateGlyphCleaner` removes a duplicate character at almost the
    /// same position as the previous one (and the spurious space PDFKit
    /// inserts between the two), so `text` is then shorter than
    /// `charRange.length`. `nil` only for compatibility with a `layout.json`
    /// written before this field or with a synthetic line in the tests
    /// (`PipelineFixtures.extractedLine`): the contiguous map is rebuilt as
    /// before.
    var charOrigins: [Int]? = nil
}

/// All the lines of a page plus its dimensions, produced by the MainActor
/// extraction (`LineExtractor`, PDFKit) and consumed by the pure cleaning
/// (`actor TextPipeline`). Codable for the regenerable cache (SPEC §7.1:
/// `~/Library/Caches/LelePdf/<fingerprint>/layout.json`).
struct PageLayout: Sendable, Codable, Equatable {
    let pageIndex: Int
    let pageRect: PageRect
    let lines: [ExtractedLine]
    /// Length of `page.string`: used by the "PDF without text" check
    /// (SPEC §5.2) without having to reopen PDFKit.
    let stringLength: Int
}

/// Version of the segmentation algorithm (SPEC §7.3 "Stable block id"): if
/// it changes, the layout cache and the saved block ids no longer reattach
/// automatically.
///
/// 2 (M2/M4 fix): `HeadingDetector`/`TextPipeline` now detect the Merck
/// case's section headings that previously slipped through (a cover-page
/// title that consumed level 1, Exhibit captions read before being
/// excluded); `sectionPath` changes for many existing blocks, so their ids
/// change. It does not invalidate anything irrecoverable: `DocumentStore
/// .updateStructure` still reattaches the saved analyses by `textHash` when
/// the id no longer matches, otherwise it marks them `orphan`.
///
/// 3 (doubled-letter fix): `LineExtractor` removes characters duplicated by
/// simulated bold/an extraction defect ("Buuildingg the Teeam" → "Building
/// the Team") before building `ExtractedLine.text`; `cleanText`/`textHash`
/// change for every block that contained a doubled letter, and so does their
/// id. The same non-destructiveness as above (reattachment by `textHash`,
/// otherwise `orphan`); a cached `layout.json` written by a previous version
/// does not have the characters removed anyway, so it must be recomputed: a
/// bump is mandatory.
enum SegmentationVersion {
    static let current = 3
}
