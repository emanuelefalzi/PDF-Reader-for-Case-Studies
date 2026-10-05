import Foundation

/// A block to render for a chat reply: a `.flow` groups consecutive text and
/// `[p. N]` citations that must run together in a single paragraph (SPEC:
/// "a chip never breaks a sentence"), while `.external` stays the dashed box
/// used for `<fuori>…</fuori>` spans.
enum ChatParagraphBlock: Sendable, Equatable {
    case flow([ChatSegment])
    case external(String)
}

/// Groups `ChatMessage.segments` into blocks (pure, no SwiftUI). The code
/// used to draw one block per segment (a `VStack` with one item per
/// element), so every `[p. 2]` chip ended up on a line of its own and split
/// the sentence (reported bug: a screenshot with "…little commercial
/// success" / "p. 2" / ". In the same period…" on separate lines).
/// `ChatController.appendSegment` already merges consecutive `.text` or
/// `.external` segments of the same kind; here alternating `.text` and
/// `.citation` segments are merged into one paragraph as well, so the
/// punctuation after a chip stays in the same block as the text it belongs to.
enum ChatParagraphGrouping {
    static func blocks(from segments: [ChatSegment]) -> [ChatParagraphBlock] {
        var result: [ChatParagraphBlock] = []
        var currentFlow: [ChatSegment] = []
        for segment in segments {
            switch segment {
            case .text, .citation:
                currentFlow.append(segment)
            case .external(let text):
                if !currentFlow.isEmpty {
                    result.append(.flow(currentFlow))
                    currentFlow = []
                }
                result.append(.external(text))
            }
        }
        if !currentFlow.isEmpty { result.append(.flow(currentFlow)) }
        return result
    }
}
