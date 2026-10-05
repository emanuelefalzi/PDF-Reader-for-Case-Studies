import SwiftUI

/// A `.flow` block as a single `AttributedString`: `[p. N]` citations become
/// an inline pill (bolder font, tinted background, clickable link) inside
/// the same paragraph as the text, so SwiftUI's text engine wraps lines
/// treating the chip like any other word. No more separate lines, and the
/// punctuation after a chip stays in the same run as the following text
/// segment (already merged by `ChatParagraphGrouping`, which adds no
/// spaces; none are added around the chip here either).
enum ChatInlineText {
    /// Placeholder scheme for the citation link, never actually opened:
    /// `.environment(\.openURL)` in `ChatPanel` intercepts it right away, so
    /// the link never leaves the app.
    static let citationScheme = "lelepdf-citation"

    static func attributedString(for segments: [ChatSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let text):
                result += AttributedString(text)
            case .citation(let label, let page):
                result += citationRun(label: label, page: page)
            case .external:
                break // rendered separately as a dashed box (ChatPanel).
            }
        }
        return result
    }

    private static func citationRun(label: String, page: Int) -> AttributedString {
        let clean = label.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var run = AttributedString(clean)
        run.font = .caption.weight(.semibold)
        run.foregroundColor = DSColor.accent
        run.backgroundColor = DSColor.accentBackground
        run.link = URL(string: "\(citationScheme):\(page)")
        return run
    }

    /// `nil` if the URL is not one of our citation links: any other link
    /// (none, today) would still be handled by the system (`.systemAction`).
    static func citationPage(from url: URL) -> Int? {
        let prefix = "\(citationScheme):"
        guard url.absoluteString.hasPrefix(prefix) else { return nil }
        return Int(url.absoluteString.dropFirst(prefix.count))
    }
}
