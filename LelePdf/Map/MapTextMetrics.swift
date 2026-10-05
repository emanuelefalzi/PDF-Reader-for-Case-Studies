import AppKit
import CoreText

/// Text measurement with the same font `MapCanvasView` uses to draw nodes
/// and link labels (SPEC §7.7). This was the main cause of the unreadable
/// map reported by the user: the layout estimated width by character count
/// (~6.7 pt/character) while the `Canvas` drew with the real system font,
/// so wide letters (capitals, "M"/"W") overflowed the node. Pure and
/// stateless: CoreText is thread-safe for reading, so it can be called from
/// `Task.detached` off the MainActor.
enum MapTextMetrics {
    /// `.bold`, not `.semibold` as in normal drawing: the layout must stay
    /// valid even when hover switches the node to `.bold` (slightly wider),
    /// otherwise hover alone would push the text out of the already-placed
    /// rectangle.
    ///
    /// `nonisolated(unsafe)`: `CTFont` is not `Sendable` to the compiler,
    /// but it is immutable and its measurement functions are thread-safe for
    /// reading (CoreText documentation): the same pattern used elsewhere in
    /// the project for system types that are not retroactively `Sendable`
    /// (`ClaudeCLILocator.swift`).
    nonisolated(unsafe) static let nodeFont: CTFont = NSFont.systemFont(ofSize: 12, weight: .bold)
    nonisolated(unsafe) static let edgeFont: CTFont = NSFont.systemFont(ofSize: 9.5, weight: .regular)

    /// Safety margin above the measured width: AppKit's metrics are not
    /// guaranteed identical to SwiftUI's text engine, so we round up instead
    /// of chasing a precision that is not needed ("no overlap" stays true
    /// with a wider margin, never with a narrower one).
    private static let safetyMargin: Double = 3

    static func width(of text: String, font: CTFont) -> Double {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return Double(CTLineGetBoundsWithOptions(line, []).width) + safetyMargin
    }

    static func lineHeight(font: CTFont) -> Double {
        Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * 1.18
    }

    /// Wraps by measured width, not by character count: a word wider than
    /// the line is split character by character (long names, URLs), the rest
    /// wraps by word.
    static func wrapLines(_ label: String, font: CTFont, maxWidth: Double, maxLines: Int) -> [String] {
        let words = label.split(whereSeparator: \.isWhitespace)
            .flatMap { splitOverlongWord(String($0), font: font, maxWidth: maxWidth) }
        guard !words.isEmpty else { return ["?"] }

        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if current.isEmpty || width(of: candidate, font: font) <= maxWidth {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }

        guard lines.count > maxLines else { return lines }
        let head = Array(lines.prefix(maxLines - 1))
        let tail = lines.dropFirst(maxLines - 1).joined(separator: " ")
        return head + [truncate(tail, font: font, maxWidth: maxWidth)]
    }

    /// Truncates to a single line with an ellipsis, at the measured width
    /// (link labels, always one line).
    static func truncate(_ text: String, font: CTFont, maxWidth: Double) -> String {
        guard width(of: text, font: font) > maxWidth else { return text }
        var result = text
        while result.count > 1, width(of: result + "…", font: font) > maxWidth {
            result.removeLast()
        }
        return result.isEmpty ? "…" : result + "…"
    }

    private static func splitOverlongWord(_ word: String, font: CTFont, maxWidth: Double) -> [String] {
        guard width(of: word, font: font) > maxWidth else { return [word] }
        var chunks: [String] = []
        var remaining = Substring(word)
        while width(of: String(remaining), font: font) > maxWidth, remaining.count > 1 {
            var cut = remaining.count - 1
            while cut > 1, width(of: String(remaining.prefix(cut)), font: font) > maxWidth { cut -= 1 }
            chunks.append(String(remaining.prefix(cut)))
            remaining = remaining.dropFirst(cut)
        }
        if !remaining.isEmpty { chunks.append(String(remaining)) }
        return chunks
    }
}
