import Foundation
import Testing
@testable import LelePdf

/// Editable text of a card ⇄ `[RewriteItem]` (SPEC §5.6 "Edit text", M7
/// deliverables 3/5): render/parse round trip for every `kind`, and the cases
/// that matter most: a marked term that is retyped (it stays) and one that is
/// deleted entirely (it disappears).
@Suite("RewriteEditText")
struct RewriteEditTextTests {
    @Test("render: a {{mX|...}} marker becomes plain text + a span at the same position")
    func renderExtractsSpan() {
        let items = [RewriteItem(kind: .paragraph, text: "Il {{m1|tasso di sconto}} è salito.")]
        let built = RewriteEditText.render(items: items)
        #expect(built.text == "Il tasso di sconto è salito.")
        #expect(built.spans == [RewriteEditText.MarkSpan(range: NSRange(location: 3, length: 15), markId: "m1")])
    }

    @Test("round trip: plain paragraph with no marks")
    func roundTripParagraph() {
        let items = [RewriteItem(kind: .paragraph, text: "Un paragrafo qualsiasi.")]
        let built = RewriteEditText.render(items: items)
        let parsed = RewriteEditText.parse(text: built.text, spans: built.spans, originalItems: items)
        #expect(parsed == items)
    }

    @Test("round trip: summary/definition/callout with an intact mark")
    func roundTripWithIntactMark() {
        let items = [
            RewriteItem(kind: .summary, text: "Il {{m1|prezzo}} è salito."),
            RewriteItem(kind: .definition, text: "Una {{m2|definizione}} chiara."),
            RewriteItem(kind: .callout, text: "Attenzione al {{m3|rischio}}."),
        ]
        let built = RewriteEditText.render(items: items)
        let parsed = RewriteEditText.parse(text: built.text, spans: built.spans, originalItems: items)
        #expect(parsed == items)
    }

    @Test("round trip: bullets and steps as text lines with a visible prefix")
    func roundTripListsAndSteps() {
        let items = [
            RewriteItem(kind: .bullets, items: ["Primo punto", "Secondo con {{m1|termine}}"]),
            RewriteItem(kind: .steps, items: ["Fai questo", "Poi quello"]),
        ]
        let built = RewriteEditText.render(items: items)
        #expect(built.text.contains("- Primo punto"))
        #expect(built.text.contains("1. Fai questo"))
        #expect(built.text.contains("2. Poi quello"))
        let parsed = RewriteEditText.parse(text: built.text, spans: built.spans, originalItems: items)
        #expect(parsed == items)
    }

    @Test("round trip: table as 'cell | cell' lines, columns preserved")
    func roundTripTable() {
        let items = [RewriteItem(kind: .table, columns: ["Anno", "Valore"], rows: [["2024", "10"], ["2025", "20"]])]
        let built = RewriteEditText.render(items: items)
        let parsed = RewriteEditText.parse(text: built.text, spans: built.spans, originalItems: items)
        #expect(parsed == items)
    }

    @Test("editing the text around an intact mark keeps it with the new words")
    func retypingKeepsMark() {
        let items = [RewriteItem(kind: .paragraph, text: "Il {{m1|tasso}} è salito molto.")]
        let built = RewriteEditText.render(items: items)
        // Simulates the user extending the marked text "tasso" -> "tasso di sconto"
        // (a real NSTextView would extend the attribute by itself when typing in the middle).
        let editedText = built.text.replacingOccurrences(of: "tasso", with: "tasso di sconto")
        let newSpan = RewriteEditText.MarkSpan(range: NSRange(location: 3, length: 15), markId: "m1")
        let parsed = RewriteEditText.parse(text: editedText, spans: [newSpan], originalItems: items)
        #expect(parsed.first?.text == "Il {{m1|tasso di sconto}} è salito molto.")
    }

    @Test("deleting a marked term entirely removes it from the marker (only the surrounding text remains)")
    func deletingMarkRemovesMarker() {
        let items = [RewriteItem(kind: .paragraph, text: "Il {{m1|tasso}} è salito.")]
        let built = RewriteEditText.render(items: items)
        // The user deletes "tasso" entirely: no span survives.
        let editedText = built.text.replacingOccurrences(of: "tasso", with: "")
        let parsed = RewriteEditText.parse(text: editedText, spans: [], originalItems: items)
        #expect(parsed.first?.text == "Il  è salito.")
        #expect(!(parsed.first?.text?.contains("{{") ?? true))
    }

    @Test("paragraph count changed: the extra items stay the original ones (graceful degradation)")
    func paragraphCountMismatchDegradesGracefully() {
        let items = [
            RewriteItem(kind: .paragraph, text: "Primo."),
            RewriteItem(kind: .paragraph, text: "Secondo."),
        ]
        // The user merges the two paragraphs into one (removes the blank line).
        let parsed = RewriteEditText.parse(text: "Primo. Secondo modificato.", spans: [], originalItems: items)
        #expect(parsed.count == 2)
        #expect(parsed[0].text == "Primo. Secondo modificato.")
        #expect(parsed[1] == items[1])
    }

    // MARK: - Per-line editing

    @Test("LineRef.whole: text(for:in:) reads the raw field of summary/paragraph/definition/callout, apply rewrites it")
    func lineRefWholeRoundTrip() throws {
        let items = [RewriteItem(kind: .paragraph, text: "Il {{m1|tasso}} è salito.")]
        let built = try #require(RewriteEditText.text(for: .whole(itemIndex: 0), in: items))
        #expect(built.text == "Il tasso è salito.")
        #expect(built.spans == [RewriteEditText.MarkSpan(range: NSRange(location: 3, length: 5), markId: "m1")])

        var mutated = items
        RewriteEditText.apply(text: "Il tasso è sceso molto.", spans: built.spans, to: .whole(itemIndex: 0), items: &mutated)
        #expect(mutated[0].text == "Il {{m1|tasso}} è sceso molto.")
    }

    @Test("LineRef.bulletMain/bulletSub: each line is read/written on its own, the others do not change")
    func lineRefBulletsAreIndependent() throws {
        let items = [RewriteItem(kind: .bullets, items: ["primo punto", "secondo {{m1|punto}}"], subItems: [["sotto a", "sotto b"], []])]

        let main1 = try #require(RewriteEditText.text(for: .bulletMain(itemIndex: 0, index: 1), in: items))
        #expect(main1.text == "secondo punto")
        var mutated = items
        RewriteEditText.apply(text: "secondo punto cambiato", spans: main1.spans, to: .bulletMain(itemIndex: 0, index: 1), items: &mutated)
        #expect(mutated[0].items?[1] == "secondo {{m1|punto}} cambiato")
        // The first line and the sub-points are untouched.
        #expect(mutated[0].items?[0] == "primo punto")
        #expect(mutated[0].subItems == items[0].subItems)

        let sub = try #require(RewriteEditText.text(for: .bulletSub(itemIndex: 0, index: 0, subIndex: 1), in: items))
        #expect(sub.text == "sotto b")
        var mutated2 = items
        RewriteEditText.apply(text: "sotto b modificato", spans: [], to: .bulletSub(itemIndex: 0, index: 0, subIndex: 1), items: &mutated2)
        #expect(mutated2[0].subItems?[0] == ["sotto a", "sotto b modificato"])
    }

    @Test("LineRef.step/tableCell/outlineLine: exact round trip")
    func lineRefStepsTableOutline() throws {
        let steps = [RewriteItem(kind: .steps, items: ["primo", "secondo"])]
        var mutatedSteps = steps
        RewriteEditText.apply(text: "primo cambiato", spans: [], to: .step(itemIndex: 0, index: 0), items: &mutatedSteps)
        #expect(mutatedSteps[0].items == ["primo cambiato", "secondo"])

        let table = [RewriteItem(kind: .table, columns: ["A", "B"], rows: [["1", "2"], ["3", "4"]])]
        let cell = try #require(RewriteEditText.text(for: .tableCell(itemIndex: 0, row: 1, col: 0), in: table))
        #expect(cell.text == "3")
        var mutatedTable = table
        RewriteEditText.apply(text: "30", spans: [], to: .tableCell(itemIndex: 0, row: 1, col: 0), items: &mutatedTable)
        #expect(mutatedTable[0].rows == [["1", "2"], ["30", "4"]])

        let outline = [RewriteItem(kind: .outline, lines: [RewriteLine(type: .point, text: "un punto"), RewriteLine(type: .note, text: "una nota")])]
        var mutatedOutline = outline
        RewriteEditText.apply(text: "una nota cambiata", spans: [], to: .outlineLine(itemIndex: 0, index: 1), items: &mutatedOutline)
        #expect(mutatedOutline[0].lines?[1].text == "una nota cambiata")
        #expect(mutatedOutline[0].lines?[1].type == .note) // the type never changes here, only the text
        #expect(mutatedOutline[0].lines?[0].text == "un punto")
    }

    @Test("LineRef out of range: text(for:in:) is nil, apply touches nothing (card changed under our feet)")
    func lineRefOutOfBoundsIsHarmless() {
        let items = [RewriteItem(kind: .paragraph, text: "Solo un item.")]
        #expect(RewriteEditText.text(for: .whole(itemIndex: 5), in: items) == nil)
        #expect(RewriteEditText.text(for: .bulletMain(itemIndex: 0, index: 0), in: items) == nil)
        var mutated = items
        RewriteEditText.apply(text: "x", spans: [], to: .bulletMain(itemIndex: 3, index: 0), items: &mutated)
        #expect(mutated == items)
    }

    @Test("firstLineRef: first editable line of every kind, skips an empty structured item")
    func firstLineRefPicksFirstEditableLine() {
        #expect(RewriteEditText.firstLineRef(items: [RewriteItem(kind: .summary, text: "s")]) == .whole(itemIndex: 0))
        #expect(RewriteEditText.firstLineRef(items: [RewriteItem(kind: .bullets, items: []), RewriteItem(kind: .steps, items: ["a"])]) == .step(itemIndex: 1, index: 0))
        #expect(RewriteEditText.firstLineRef(items: [RewriteItem(kind: .table, columns: [], rows: [])]) == nil)
        #expect(RewriteEditText.firstLineRef(items: []) == nil)
    }
}
