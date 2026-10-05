import Foundation
import Testing
@testable import LelePdf

/// Grouping of segments into paragraphs: reproduces the reported screenshot
/// ("…scarso successo commerciale" / "p. 2" / ". Nello stesso periodo…" on
/// separate lines) at the model level, with no need for SwiftUI.
@Suite("ChatParagraphGrouping")
struct ChatParagraphGroupingTests {
    @Test("text + citation + text stay a single flow block (no paragraph break)")
    func citationDoesNotBreakParagraph() {
        let segments: [ChatSegment] = [
            .text("Il documento descrive scarso successo commerciale"),
            .citation(label: "[p. 2]", page: 2),
            .text(". Nello stesso periodo il mercato cresceva."),
        ]
        let blocks = ChatParagraphGrouping.blocks(from: segments)
        #expect(blocks == [.flow(segments)])
    }

    @Test("punctuation after a chip stays in the same block as the chip")
    func punctuationAfterChipStaysInSameParagraph() {
        let segments: [ChatSegment] = [
            .text("Testo prima"),
            .citation(label: "[p. 5]", page: 5),
            .text(", continua."),
        ]
        let blocks = ChatParagraphGrouping.blocks(from: segments)
        guard let first = blocks.first, case .flow(let flow) = first else {
            Issue.record("expected a flow block")
            return
        }
        #expect(flow.last == .text(", continua."))
        #expect(blocks.count == 1)
    }

    @Test("several consecutive citations stay in the same flow block")
    func multipleCitationsInARowStayTogether() {
        let segments: [ChatSegment] = [
            .text("Vedi "),
            .citation(label: "[p. 1]", page: 1),
            .text(" e "),
            .citation(label: "[p. 2]", page: 2),
            .text("."),
        ]
        #expect(ChatParagraphGrouping.blocks(from: segments) == [.flow(segments)])
    }

    @Test("an external block (<fuori>) splits the flow into a separate block, without losing segments")
    func externalSplitsFlowIntoSeparateBlock() {
        let segments: [ChatSegment] = [
            .text("Prima parte"),
            .citation(label: "[p. 1]", page: 1),
            .external("nota esterna"),
            .text(". Dopo la nota."),
        ]
        #expect(ChatParagraphGrouping.blocks(from: segments) == [
            .flow([.text("Prima parte"), .citation(label: "[p. 1]", page: 1)]),
            .external("nota esterna"),
            .flow([.text(". Dopo la nota.")]),
        ])
    }

    @Test("empty segments produce no blocks")
    func emptySegmentsProduceNoBlocks() {
        #expect(ChatParagraphGrouping.blocks(from: []).isEmpty)
    }
}
