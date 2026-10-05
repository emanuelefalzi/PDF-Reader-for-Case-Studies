import Foundation

/// Matches a generated contents entry (Claude, SPEC §7.4) to the heading
/// detected by the pipeline (`Heading`, SPEC §7.3) on the same page, to fill
/// in `pageY` (SPEC §8, v2.3 §5.3). Pure, no dependency on PDFKit.
///
/// **A reported bug**: clicking a heading to go to that section, when there
/// were two headings on the same page, only took the user to the first one
/// that appears; generated entries never carried `pageY` (only `page`), so
/// every heading on the same page ended up in the same place (the start of
/// the page). By matching each entry to the `Heading` that originated it,
/// the real rectangle of the heading line (`Heading.rect`) is recovered, whose
/// `maxY` (page space, y grows upward) is already the `pageY` convention used
/// by manual entries (M7).
enum TocHeadingMatch {
    /// `pageIndex` is 0-based, like `Heading.pageIndex`. `nil` if no heading
    /// is found on that page that resembles the title sought (SPEC "keeps
    /// working even without a match": the caller falls back to the page jump
    /// alone).
    static func pageY(forTitle title: String, pageIndex: Int, headings: [Heading]) -> Double? {
        let candidates = headings.filter { $0.pageIndex == pageIndex }
        guard !candidates.isEmpty else { return nil }
        let normalizedTitle = TermRegistry.normalize(title)

        if let exact = candidates.first(where: { TermRegistry.normalize($0.text) == normalizedTitle }) {
            return Double(exact.rect.maxY)
        }
        // Claude "cleans up" the candidates (SPEC §7.4): the generated title
        // can be a slightly shortened/reformatted version of the detected
        // text. Containment in both directions as a fallback, before giving
        // up on the page's only heading (if there is no ambiguity).
        if !normalizedTitle.isEmpty, let contains = candidates.first(where: {
            let normalizedHeading = TermRegistry.normalize($0.text)
            return !normalizedHeading.isEmpty && (normalizedHeading.contains(normalizedTitle) || normalizedTitle.contains(normalizedHeading))
        }) {
            return Double(contains.rect.maxY)
        }
        if candidates.count == 1 { return Double(candidates[0].rect.maxY) }
        return nil
    }
}
