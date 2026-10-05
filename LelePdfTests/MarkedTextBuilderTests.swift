import Foundation
import Testing
@testable import LelePdf

/// Resolved segments → plain text + marked ranges (M5b deliverable 7 "text
/// attribute building from rewrite items").
@Suite("MarkedTextBuilder")
struct MarkedTextBuilderTests {
    @Test("plain text only: no marked range")
    func plainOnly() {
        let built = MarkedTextBuilder.build([.plain("ciao mondo")])
        #expect(built.text == "ciao mondo")
        #expect(built.marks.isEmpty)
    }

    @Test("a marked segment produces a range with the correct termId and type")
    func singleMarkedSegment() {
        let built = MarkedTextBuilder.build([.plain("Il "), .marked(text: "debitore", termId: "t1", type: .circle), .plain(" paga.")])
        #expect(built.text == "Il debitore paga.")
        #expect(built.marks.count == 1)
        let mark = built.marks[0]
        #expect(mark.termId == "t1")
        #expect(mark.type == .circle)
        #expect(mark.range == NSRange(location: 3, length: 8))
        #expect((built.text as NSString).substring(with: mark.range) == "debitore")
    }

    @Test("several consecutive marks stay in distinct, non-overlapping ranges")
    func multipleMarkedSegments() {
        let built = MarkedTextBuilder.build([
            .marked(text: "Obbligazione", termId: "t1", type: .rectangle),
            .plain(" tra "),
            .marked(text: "debitore", termId: "t2", type: .circle),
            .plain(" e "),
            .marked(text: "creditore", termId: "t2", type: .circle),
        ])
        #expect(built.marks.count == 3)
        #expect(built.marks.map(\.termId) == ["t1", "t2", "t2"])
        for mark in built.marks {
            #expect((built.text as NSString).substring(with: mark.range) == (mark.termId == "t1" ? "Obbligazione" : (mark.range.location < 20 ? "debitore" : "creditore")))
        }
    }

    @Test("multiple lines (list/table) are joined with a separator and the ranges stay correct")
    func multipleLines() {
        let built = MarkedTextBuilder.build(lines: [
            [.plain("Prima riga: "), .marked(text: "termine", termId: "t1", type: .underline)],
            [.plain("Seconda riga")],
        ])
        #expect(built.text == "Prima riga: termine\nSeconda riga")
        #expect(built.marks.count == 1)
        #expect((built.text as NSString).substring(with: built.marks[0].range) == "termine")
    }

    @Test("empty segments do not yield a useful zero-length range but stay consistent")
    func emptyMarkedSegment() {
        let built = MarkedTextBuilder.build([.marked(text: "", termId: "t1", type: .arrow)])
        #expect(built.text == "")
        #expect(built.marks == [MarkedTextBuilder.MarkedRange(range: NSRange(location: 0, length: 0), termId: "t1", type: .arrow)])
    }
}
