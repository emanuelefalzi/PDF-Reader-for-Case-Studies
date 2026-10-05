import Foundation
import Testing
@testable import LelePdf

/// Post-processing (SPEC §7.5 items 1-2-3-5):
/// clean→page conversion (also across a page break), term registry applied
/// in order, links, marker sanitizing.
@Suite("AnalysisPostProcessor")
struct AnalysisPostProcessorTests {
    private func block(cleanText: String, spans: [BlockPageSpan], id: String = "b1") -> TextBlock {
        TextBlock(id: id, sectionPath: ["Sezione"], pageStart: spans.first?.page ?? 0, pageEnd: spans.last?.page ?? 0, cleanText: cleanText, textHash: "hash", words: cleanText.split(separator: " ").count, spans: spans, lineRectsByPage: [:])
    }

    /// Flat block (a single span, page 2, identity char map).
    private func flatBlock(_ text: String, page: Int = 2) -> TextBlock {
        block(cleanText: text, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], id: "b1")
    }

    @Test("matched mark: page and clean-text range stored correctly")
    func matchedMarkStoresCleanRangeAndPage() throws {
        let text = "La FDA ha approvato il farmaco."
        let response = AnalysisResponseRaw(title: "T", rewrite: [], marks: [
            AnalysisMarkRaw(id: "m1", text: "FDA", mark: .circle, term: "FDA", termId: nil),
        ], links: [])
        let output = AnalysisPostProcessor.process(.init(response: response, block: flatBlock(text), existingTerms: [:]))

        #expect(output.marks.count == 1)
        let mark = try #require(output.marks.first)
        #expect(mark.page == 2)
        let expectedStart = text.distance(from: text.startIndex, to: text.range(of: "FDA")!.lowerBound)
        #expect(mark.range.start == expectedStart)
        #expect(mark.range.length == 3)
        #expect(output.droppedMarkCount == 0)
    }

    @Test("a mark without a match is dropped and counted")
    func unmatchedMarkDropped() {
        let response = AnalysisResponseRaw(title: "T", rewrite: [], marks: [
            AnalysisMarkRaw(id: "m1", text: "Testo assente", mark: .rectangle, term: "x", termId: nil),
        ], links: [])
        let output = AnalysisPostProcessor.process(.init(response: response, block: flatBlock("Testo del blocco."), existingTerms: [:]))
        #expect(output.marks.isEmpty)
        #expect(output.droppedMarkCount == 1)
        #expect(output.totalMarkCount == 1)
    }

    @Test("a mark with empty text is dropped before matching")
    func emptyTextMarkDropped() {
        let response = AnalysisResponseRaw(title: "T", rewrite: [], marks: [
            AnalysisMarkRaw(id: "m1", text: "   ", mark: .rectangle, term: "x", termId: nil),
        ], links: [])
        let output = AnalysisPostProcessor.process(.init(response: response, block: flatBlock("Testo del blocco."), existingTerms: [:]))
        #expect(output.marks.isEmpty)
        #expect(output.droppedMarkCount == 1)
    }

    @Test("mark spanning a page break: the block's first page is stored")
    func markSpanningPageBreakUsesFirstPage() throws {
        let spanA = BlockPageSpan(page: 3, cleanStart: 0, cleanLength: 10, charMap: Array(100 ..< 110))
        let spanB = BlockPageSpan(page: 4, cleanStart: 10, cleanLength: 8, charMap: Array(0 ..< 8))
        let crossPageBlock = block(cleanText: "0123456789ABCDEFGH", spans: [spanA, spanB])

        let response = AnalysisResponseRaw(title: "T", rewrite: [], marks: [
            AnalysisMarkRaw(id: "m1", text: "89ABC", mark: .rectangle, term: "x", termId: nil),
        ], links: [])
        let output = AnalysisPostProcessor.process(.init(response: response, block: crossPageBlock, existingTerms: [:]))

        let mark = try #require(output.marks.first)
        #expect(mark.page == 3) // first page touched by the range
        #expect(mark.range.start == 8)
        #expect(mark.range.length == 5)
    }

    @Test("term registry applied in order: two new marks with the same term mint the same termId")
    func newTermIdSharedWithinBlock() {
        let text = "Il Farmaco X è stato approvato. Il Farmaco X ha avuto successo."
        let response = AnalysisResponseRaw(title: "T", rewrite: [], marks: [
            AnalysisMarkRaw(id: "m1", text: "Farmaco X", mark: .rectangle, term: "Farmaco X", termId: nil),
            AnalysisMarkRaw(id: "m2", text: "Farmaco X", mark: .rectangle, term: "farmaco x", termId: nil),
        ], links: [])
        let output = AnalysisPostProcessor.process(.init(response: response, block: flatBlock(text), existingTerms: [:]))
        #expect(output.marks.count == 2)
        #expect(output.marks[0].termId == output.marks[1].termId)
        #expect(output.newTerms.count == 1)
    }

    @Test("a link with both endpoints resolved is kept")
    func linkWithBothEndpointsResolved() {
        let text = "Il CEO ha deciso di investire, causando una crescita."
        let response = AnalysisResponseRaw(title: "T", rewrite: [], marks: [
            AnalysisMarkRaw(id: "m1", text: "CEO", mark: .circle, term: "CEO", termId: nil),
            AnalysisMarkRaw(id: "m2", text: "deciso", mark: .underline, term: "decisione", termId: nil),
        ], links: [
            AnalysisLinkRaw(from: "m1", to: "m2", via: nil, label: "decide", kind: .action),
        ])
        let output = AnalysisPostProcessor.process(.init(response: response, block: flatBlock(text), existingTerms: [:]))
        #expect(output.links.count == 1)
        #expect(output.links[0].from == output.marks[0].termId)
        #expect(output.links[0].to == output.marks[1].termId)
    }

    @Test("a link with an unresolved endpoint is dropped entirely")
    func linkWithUnresolvedEndpointDropped() {
        let text = "Il CEO ha deciso di investire."
        let response = AnalysisResponseRaw(title: "T", rewrite: [], marks: [
            AnalysisMarkRaw(id: "m1", text: "CEO", mark: .circle, term: "CEO", termId: nil),
        ], links: [
            AnalysisLinkRaw(from: "m1", to: "m-inesistente", via: nil, label: "x", kind: .action),
        ])
        let output = AnalysisPostProcessor.process(.init(response: response, block: flatBlock(text), existingTerms: [:]))
        #expect(output.links.isEmpty)
    }

    @Test("unresolved via: the link stays but without a via")
    func viaDroppedButLinkKept() {
        let text = "Il CEO ha deciso di investire, causando crescita."
        let response = AnalysisResponseRaw(title: "T", rewrite: [], marks: [
            AnalysisMarkRaw(id: "m1", text: "CEO", mark: .circle, term: "CEO", termId: nil),
            AnalysisMarkRaw(id: "m2", text: "crescita", mark: .arrow, term: "crescita", termId: nil),
        ], links: [
            AnalysisLinkRaw(from: "m1", to: "m2", via: "m-scartato", label: "porta a", kind: .effect),
        ])
        let output = AnalysisPostProcessor.process(.init(response: response, block: flatBlock(text), existingTerms: [:]))
        #expect(output.links.count == 1)
        #expect(output.links[0].via == nil)
    }

    @Test("resolved via (mark kept) stays on the link")
    func viaKeptWhenResolved() {
        let text = "Il CEO ha deciso di investire, causando crescita."
        let response = AnalysisResponseRaw(title: "T", rewrite: [], marks: [
            AnalysisMarkRaw(id: "m1", text: "CEO", mark: .circle, term: "CEO", termId: nil),
            AnalysisMarkRaw(id: "m2", text: "crescita", mark: .arrow, term: "crescita", termId: nil),
            AnalysisMarkRaw(id: "m3", text: "deciso", mark: .underline, term: "decisione", termId: nil),
        ], links: [
            AnalysisLinkRaw(from: "m1", to: "m2", via: "m3", label: "porta a", kind: .effect),
        ])
        let output = AnalysisPostProcessor.process(.init(response: response, block: flatBlock(text), existingTerms: [:]))
        #expect(output.links.count == 1)
        #expect(output.links[0].via == "m3")
    }

    @Test("a marker with a dropped id becomes plain text, a valid marker stays intact")
    func markerSanitizingDropsUnknownKeepsKnown() {
        let text = "Il CEO ha deciso di investire."
        let response = AnalysisResponseRaw(title: "T", rewrite: [
            RewriteItem(kind: .summary, text: "{{m1|il CEO}} ha agito, {{m2|inesistente}} qui."),
        ], marks: [
            AnalysisMarkRaw(id: "m1", text: "CEO", mark: .circle, term: "CEO", termId: nil),
        ], links: [])
        let output = AnalysisPostProcessor.process(.init(response: response, block: flatBlock(text), existingTerms: [:]))
        let rendered = output.rewrite.first?.text
        #expect(rendered == "{{m1|il CEO}} ha agito, inesistente qui.")
    }

    @Test("table truncated to 4 columns and 8 rows, not rejected")
    func tableTruncatedNotRejected() throws {
        let columns = (1 ... 6).map { "Col\($0)" }
        let rows = (1 ... 12).map { r in (1 ... 6).map { "r\(r)c\($0)" } }
        let response = AnalysisResponseRaw(title: "T", rewrite: [RewriteItem(kind: .table, columns: columns, rows: rows)], marks: [], links: [])
        let output = AnalysisPostProcessor.process(.init(response: response, block: flatBlock("Testo."), existingTerms: [:]))
        let table = try #require(output.rewrite.first)
        #expect(table.columns?.count == 4)
        #expect(table.rows?.count == 8)
        #expect(table.rows?.first?.count == 4)
    }
}
