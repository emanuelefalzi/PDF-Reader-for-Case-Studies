import Foundation
import Testing
@testable import LelePdf

/// Backward-compatible decoding (a leading "→ " arrow reads as a
/// consequence) and graceful degradation of a malformed `lines` sequence
/// (`OutlineLinesNormalizer`, the same principle as
/// `BulletSubItemsNormalizer`).
@Suite("RewriteOutlineReader and RewriteLineType: decoding and backward compatibility")
struct RewriteOutlineReaderTests {
    @Test("kind == .outline: the lines come back exactly as saved")
    func outlineKindReturnsLinesAsIs() {
        let item = RewriteItem(kind: .outline, lines: [
            RewriteLine(type: .point, text: "Primo punto"),
            RewriteLine(type: .subpoint, text: "Dettaglio"),
            RewriteLine(type: .note, text: "Una nota"),
        ])
        let lines = RewriteOutlineReader.lines(for: item)
        #expect(lines.map(\.type) == [.point, .subpoint, .note])
        #expect(lines.map(\.text) == ["Primo punto", "Dettaglio", "Una nota"])
    }

    @Test("kind == .bullets saved by an older version: items/subItems become point/subpoint")
    func legacyBulletsBecomePointsAndSubpoints() {
        let item = RewriteItem(kind: .bullets, items: ["Punto uno", "Punto due"], subItems: [["Dettaglio uno"], []])
        let lines = RewriteOutlineReader.lines(for: item)
        #expect(lines.map(\.type) == [.point, .subpoint, .point])
        #expect(lines.map(\.text) == ["Punto uno", "Dettaglio uno", "Punto due"])
    }

    @Test("the old '→ ' arrow at the start of a point reads as a consequence, removed from the text")
    func legacyArrowReadsAsConsequence() {
        let item = RewriteItem(kind: .bullets, items: ["→ Effetto di prima", "Punto normale"], subItems: nil)
        let lines = RewriteOutlineReader.lines(for: item)
        #expect(lines == [
            RewriteLine(type: .consequence, text: "Effetto di prima"),
            RewriteLine(type: .point, text: "Punto normale"),
        ])
    }

    @Test("the old ASCII '-> ' arrow (before the prompt fix) also reads as a consequence")
    func legacyAsciiArrowReadsAsConsequence() {
        let item = RewriteItem(kind: .bullets, items: ["-> Effetto ASCII"], subItems: nil)
        let lines = RewriteOutlineReader.lines(for: item)
        #expect(lines == [RewriteLine(type: .consequence, text: "Effetto ASCII")])
    }

    @Test("a legacy sub-point with the arrow also becomes a consequence, not a sub-point")
    func legacyArrowInSubItemBecomesConsequence() {
        let item = RewriteItem(kind: .bullets, items: ["Punto"], subItems: [["→ Effetto annidato"]])
        let lines = RewriteOutlineReader.lines(for: item)
        #expect(lines == [
            RewriteLine(type: .point, text: "Punto"),
            RewriteLine(type: .consequence, text: "Effetto annidato"),
        ])
    }

    @Test("a kind other than outline/bullets: no lines (it keeps its own rendering and does not touch this reader)")
    func otherKindsProduceNoLines() {
        #expect(RewriteOutlineReader.lines(for: RewriteItem(kind: .summary, text: "Sommario")).isEmpty)
        #expect(RewriteOutlineReader.lines(for: RewriteItem(kind: .table, columns: ["A"], rows: [["1"]])).isEmpty)
    }

    @Test("an unknown line type (future schema) decodes as .other, never a crash")
    func unknownLineTypeDecodesAsOther() throws {
        let json = #"{"type":"un-tipo-futuro","text":"testo"}"#
        let line = try JSONDecoder().decode(RewriteLine.self, from: Data(json.utf8))
        #expect(line.type == .other("un-tipo-futuro"))
        #expect(line.type.rawValue == "un-tipo-futuro")
        // It can be rewritten without losing the raw value (forward compatible).
        let reencoded = try JSONEncoder().encode(line)
        let redecoded = try JSONDecoder().decode(RewriteLine.self, from: reencoded)
        #expect(redecoded.type == .other("un-tipo-futuro"))
    }

    @Test("isNested: only sub-point and explanation nest under the preceding point/consequence")
    func isNestedOnlyForSubpointAndExplanation() {
        #expect(RewriteLineType.subpoint.isNested)
        #expect(RewriteLineType.explanation.isNested)
        for type: RewriteLineType in [.point, .consequence, .note, .formula, .subheading] {
            #expect(!type.isNested)
        }
    }
}

/// `OutlineLinesNormalizer`: graceful degradation of a sequence that does not
/// respect "a point before every sub-point/explanation" or "at most one
/// explanation per point"; the JSON schema cannot enforce either on its own
/// (the same principle as `BulletSubItemsNormalizerTests`, if present, for
/// `subItems`).
@Suite("OutlineLinesNormalizer: graceful degradation")
struct OutlineLinesNormalizerTests {
    @Test("a non-outline item is left untouched")
    func nonOutlineItemUnchanged() {
        let item = RewriteItem(kind: .summary, text: "Sommario")
        #expect(OutlineLinesNormalizer.align(item) == item)
    }

    @Test("a sub-point BEFORE any point becomes a point")
    func leadingSubpointBecomesPoint() {
        let item = RewriteItem(kind: .outline, lines: [
            RewriteLine(type: .subpoint, text: "Orfano"),
            RewriteLine(type: .point, text: "Primo punto vero"),
        ])
        let aligned = OutlineLinesNormalizer.align(item)
        #expect(aligned.lines == [
            RewriteLine(type: .point, text: "Orfano"),
            RewriteLine(type: .point, text: "Primo punto vero"),
        ])
    }

    @Test("a second explanation under the same point becomes a sub-point")
    func secondExplanationBecomesSubpoint() {
        let item = RewriteItem(kind: .outline, lines: [
            RewriteLine(type: .point, text: "Punto"),
            RewriteLine(type: .explanation, text: "Prima spiegazione"),
            RewriteLine(type: .explanation, text: "Seconda spiegazione (troppe)"),
        ])
        let aligned = OutlineLinesNormalizer.align(item)
        #expect(aligned.lines == [
            RewriteLine(type: .point, text: "Punto"),
            RewriteLine(type: .explanation, text: "Prima spiegazione"),
            RewriteLine(type: .subpoint, text: "Seconda spiegazione (troppe)"),
        ])
    }

    @Test("a new point resets the explanation count: each can have its own")
    func explanationCountResetsPerPoint() {
        let item = RewriteItem(kind: .outline, lines: [
            RewriteLine(type: .point, text: "Punto A"),
            RewriteLine(type: .explanation, text: "Spiegazione A"),
            RewriteLine(type: .point, text: "Punto B"),
            RewriteLine(type: .explanation, text: "Spiegazione B"),
        ])
        let aligned = OutlineLinesNormalizer.align(item)
        #expect(aligned.lines?.map(\.type) == [.point, .explanation, .point, .explanation])
    }
}
