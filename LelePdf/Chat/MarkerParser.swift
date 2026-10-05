import Foundation

/// A chunk of chat text that has already been interpreted (SPEC §7.8
/// "Streaming parser"): a page citation or plain text, with a flag telling
/// whether it sits inside `<fuori>…</fuori>` (knowledge from outside the PDF).
enum ChatMarkerEvent: Sendable, Equatable {
    case text(String, external: Bool)
    /// `label` is the original marker text (`"p. 12"`, `"pp. 3–5"`), `page`
    /// the first cited page (SPEC: "keeps the first page, full label").
    case citation(label: String, page: Int, external: Bool)
}

/// Turns text chunks (`ChatEvent.textDelta`) into interpreted events,
/// handling markers split across chunks (SPEC §7.8: "even when the marker
/// arrives split"). Pure: no dependency on `ChatSession`, and on Foundation
/// only `NSRegularExpression`/`String`.
final class MarkerParser {
    private var buffer = ""
    private var insideExternal = false

    /// Appends a chunk of text and returns the events that can already be
    /// emitted with certainty. The rest (a possible half-received marker)
    /// stays in `buffer` waiting for the next chunk.
    func feed(_ delta: String) -> [ChatMarkerEvent] {
        buffer += delta
        return drain(flush: false)
    }

    /// Call at the end of a response: anything left in `buffer` is no longer
    /// an incoming marker and is emitted as plain text.
    func finish() -> [ChatMarkerEvent] {
        let events = drain(flush: true)
        buffer = ""
        return events
    }

    private func drain(flush: Bool) -> [ChatMarkerEvent] {
        var events: [ChatMarkerEvent] = []
        while true {
            guard let match = Self.nextMarker(in: buffer) else { break }
            if match.range.lowerBound > buffer.startIndex {
                events.append(.text(String(buffer[buffer.startIndex..<match.range.lowerBound]), external: insideExternal))
            }
            switch match.kind {
            case .citation(let label, let page):
                events.append(.citation(label: label, page: page, external: insideExternal))
            case .externalOpen:
                insideExternal = true
            case .externalClose:
                insideExternal = false
            }
            buffer.removeSubrange(buffer.startIndex..<match.range.upperBound)
        }

        if flush {
            if !buffer.isEmpty { events.append(.text(buffer, external: insideExternal)) }
            buffer = ""
        } else {
            let holdBack = Self.possiblePartialMarkerLength(buffer)
            let safeLength = buffer.count - holdBack
            if safeLength > 0 {
                let cut = buffer.index(buffer.startIndex, offsetBy: safeLength)
                events.append(.text(String(buffer[..<cut]), external: insideExternal))
                buffer.removeSubrange(buffer.startIndex..<cut)
            }
        }
        return events
    }

    // MARK: - Marker search (pure)

    private enum MarkerKind: Equatable {
        case citation(label: String, page: Int)
        case externalOpen
        case externalClose
    }

    private struct Match {
        let range: Range<String.Index>
        let kind: MarkerKind
    }

    /// `[p. N]`, `[pp. N–M]`, `[p. N, M]`: the first number is the page kept,
    /// the label is the whole marker text.
    private static let citationRegex = try! NSRegularExpression(pattern: #"\[pp?\.\s*\d+(?:\s*[–\-,]\s*\d+)*\]"#)

    private static func nextMarker(in text: String) -> Match? {
        var earliest: Match?
        if let openRange = text.range(of: "<fuori>") {
            earliest = Match(range: openRange, kind: .externalOpen)
        }
        if let closeRange = text.range(of: "</fuori>"), earliest == nil || closeRange.lowerBound < earliest!.range.lowerBound {
            earliest = Match(range: closeRange, kind: .externalClose)
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = citationRegex.firstMatch(in: text, range: nsRange), let range = Range(match.range, in: text) {
            if earliest == nil || range.lowerBound < earliest!.range.lowerBound {
                let label = String(text[range])
                let page = firstNumber(in: label) ?? 1
                earliest = Match(range: range, kind: .citation(label: label, page: page))
            }
        }
        return earliest
    }

    private static func firstNumber(in text: String) -> Int? {
        var digits = ""
        for char in text {
            if char.isNumber {
                digits.append(char)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }

    /// How many trailing characters of `text` must be held back because they
    /// could become the start of a marker once more text arrives (SPEC:
    /// "split across events"): only a trailing `[`/`<` whose tail is still
    /// compatible with `[p...]`/`[pp...]`/`<fuori>`/`</fuori>` blocks
    /// emission; everything else is safe text.
    private static func possiblePartialMarkerLength(_ text: String) -> Int {
        guard let lastOpener = text.lastIndex(where: { $0 == "[" || $0 == "<" }) else { return 0 }
        let suffix = text[lastOpener...]
        if suffix.hasPrefix("["), isPlausibleCitationPrefix(suffix) { return suffix.count }
        if suffix.hasPrefix("<"), isPlausibleExternalTagPrefix(suffix) { return suffix.count }
        return 0
    }

    private enum CitationState { case start, bracket, p1, p2, afterP, body }

    private static func isPlausibleCitationPrefix(_ suffix: Substring) -> Bool {
        var state = CitationState.start
        for char in suffix {
            switch (state, char) {
            case (.start, "["): state = .bracket
            case (.bracket, "p"): state = .p1
            case (.p1, "p"): state = .p2
            case (.p1, "."), (.p2, "."): state = .afterP
            case (.afterP, " "): state = .afterP
            case (.afterP, let c) where c.isNumber: state = .body
            case (.body, let c) where c.isNumber || c == "," || c == "-" || c == "\u{2013}" || c == " ": state = .body
            default: return false
            }
        }
        return true
    }

    private static let externalPrefixes: Set<String> = [
        "<", "<f", "<fu", "<fuo", "<fuor", "<fuori", "<fuori>",
        "</", "</f", "</fu", "</fuo", "</fuor", "</fuori", "</fuori>",
    ]

    private static func isPlausibleExternalTagPrefix(_ suffix: Substring) -> Bool {
        externalPrefixes.contains(String(suffix))
    }
}
