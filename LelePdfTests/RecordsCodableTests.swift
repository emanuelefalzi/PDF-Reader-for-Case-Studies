import Testing
import Foundation
@testable import LelePdf

/// Codable round trip of the two saved files (SPEC §8, §10.2 "Store: round
/// trip"), with all element types and the forward compatibility of a block's
/// status.
@Suite("Records Codable")
struct RecordsCodableTests {
    @Test("DocumentRecord: round trip")
    @MainActor
    func documentRecordRoundTrip() throws {
        let original = StoreFixtures.sampleDocumentRecord()
        let data = try AtomicJSONFile.encode(original)
        let decoded = try AtomicJSONFile.decoder.decode(DocumentRecord.self, from: data)
        #expect(decoded == original)
    }

    @Test("DocumentRecord: round trip without colorTheme (never chosen)")
    @MainActor
    func documentRecordRoundTripWithoutColorTheme() throws {
        let original = StoreFixtures.sampleDocumentRecord(colorTheme: nil)
        #expect(original.colorTheme == nil)
        let data = try AtomicJSONFile.encode(original)
        let decoded = try AtomicJSONFile.decoder.decode(DocumentRecord.self, from: data)
        #expect(decoded == original)
        #expect(decoded.colorTheme == nil)
    }

    @Test("documento.json written before v2.6 (without the colorTheme key) stays readable")
    func colorThemeBackwardCompatibleDecoding() throws {
        // SPEC §5.4 v2.6 "colorTheme": a field added after M0-M10. A
        // `documento.json` written earlier has no such key at all (not just
        // `null`), so decoding must treat it as absent rather than fail.
        let json = """
        {"version":1,"fingerprint":"abc","fileName":"x.pdf","lastKnownPath":"/tmp/x.pdf",\
        "pageCount":1,"title":"X","toc":{"source":"native","entries":[]},\
        "segmentationVersion":1,"blocks":[],"exhibits":[],\
        "progress":{"analyzedBlockIds":[],"lastReadPage":0},"updatedAt":"2026-09-16T09:00:00Z"}
        """
        let decoded = try AtomicJSONFile.decoder.decode(DocumentRecord.self, from: Data(json.utf8))
        #expect(decoded.colorTheme == nil)

        // And it can be rewritten/reread without losing the `nil` (it is not
        // turned into a random value, nor does it make a later rewrite fail).
        let reencoded = try AtomicJSONFile.encode(decoded)
        let roundTripped = try AtomicJSONFile.decoder.decode(DocumentRecord.self, from: reencoded)
        #expect(roundTripped == decoded)
    }

    @Test("AnalysisRecord: round trip with all elements")
    @MainActor
    func analysisRecordRoundTrip() throws {
        let original = StoreFixtures.sampleAnalysisRecord()
        let data = try AtomicJSONFile.encode(original)
        let decoded = try AtomicJSONFile.decoder.decode(AnalysisRecord.self, from: data)
        #expect(decoded == original)
    }

    @Test("an unknown status in analisi.json stays readable and does not make the file fail")
    func unknownStatusForwardCompatible() throws {
        let json = """
        {"version":1,"terms":{},"blocks":{"b1":{"status":"summarizing","marks":[],"links":[],"rewrite":[],"claudeRewrite":[],"rewriteEdited":false}}}
        """
        let decoded = try AtomicJSONFile.decoder.decode(AnalysisRecord.self, from: Data(json.utf8))
        #expect(decoded.blocks["b1"]?.status == .other("summarizing"))
        #expect(decoded.blocks["b1"]?.status.rawValue == "summarizing")
        // This JSON predates the addition of claudeMarks/claudeLinks: they
        // must decode to `nil` (snapshot not available), neither failing the
        // file nor wrongly becoming `[]` ("Claude produced no marks").
        #expect(decoded.blocks["b1"]?.claudeMarks == nil)
        #expect(decoded.blocks["b1"]?.claudeLinks == nil)

        // And it can be rewritten without losing the raw value.
        let reencoded = try AtomicJSONFile.encode(decoded)
        let roundTripped = try AtomicJSONFile.decoder.decode(AnalysisRecord.self, from: reencoded)
        #expect(roundTripped == decoded)
    }

    @Test("analisi.json written before claudeMarks/claudeLinks existed stays readable")
    func claudeMarksBackwardCompatibleDecoding() throws {
        let json = """
        {"version":1,"terms":{},"blocks":{"b1":{"status":"analyzed","marks":[],"links":[],"rewrite":[],"claudeRewrite":[],"rewriteEdited":false}}}
        """
        let decoded = try AtomicJSONFile.decoder.decode(AnalysisRecord.self, from: Data(json.utf8))
        #expect(decoded.blocks["b1"]?.claudeMarks == nil)
        #expect(decoded.blocks["b1"]?.claudeLinks == nil)

        let reencoded = try AtomicJSONFile.encode(decoded)
        let roundTripped = try AtomicJSONFile.decoder.decode(AnalysisRecord.self, from: reencoded)
        #expect(roundTripped == decoded)
    }

    @Test("known statuses stay as expected")
    func knownStatusValues() {
        #expect(BlockAnalysisStatus(rawValue: "analyzed") == .analyzed)
        #expect(BlockAnalysisStatus(rawValue: "orphan") == .orphan)
        #expect(BlockAnalysisStatus(rawValue: "failed") == .failed)
    }

    @Test("documento.json written before summaryGranularity existed stays readable, nil")
    func summaryGranularityBackwardCompatibleDecoding() throws {
        // A field added later: a `documento.json` written earlier has no
        // such key at all, same principle as `colorTheme` above: absent, not
        // `null`.
        let json = """
        {"version":1,"fingerprint":"abc","fileName":"x.pdf","lastKnownPath":"/tmp/x.pdf",\
        "pageCount":1,"title":"X","toc":{"source":"native","entries":[]},\
        "segmentationVersion":1,"blocks":[],"exhibits":[],\
        "progress":{"analyzedBlockIds":[],"lastReadPage":0},"updatedAt":"2026-09-16T09:00:00Z"}
        """
        let decoded = try AtomicJSONFile.decoder.decode(DocumentRecord.self, from: Data(json.utf8))
        #expect(decoded.summaryGranularity == nil)

        let reencoded = try AtomicJSONFile.encode(decoded)
        let roundTripped = try AtomicJSONFile.decoder.decode(DocumentRecord.self, from: reencoded)
        #expect(roundTripped == decoded)
        #expect(roundTripped.summaryGranularity == nil)
    }

    @Test("DocumentRecord: round trip with summaryGranularity chosen")
    @MainActor
    func documentRecordRoundTripWithSummaryGranularity() throws {
        var original = StoreFixtures.sampleDocumentRecord()
        original.summaryGranularity = .chapter
        let data = try AtomicJSONFile.encode(original)
        let decoded = try AtomicJSONFile.decoder.decode(DocumentRecord.self, from: data)
        #expect(decoded == original)
        #expect(decoded.summaryGranularity == .chapter)
    }

    @Test("title: meaningful metadata wins over the file name, otherwise the name without extension")
    func documentTitleResolution() {
        #expect(DocumentTitle.resolve(metadataTitle: "The Future of Competitiveness", fileName: "draghi.pdf") == "The Future of Competitiveness")
        #expect(DocumentTitle.resolve(metadataTitle: nil, fileName: "Strategy in the pharma industry.pdf") == "Strategy in the pharma industry")
        #expect(DocumentTitle.resolve(metadataTitle: "", fileName: "merck.pdf") == "merck")
        #expect(DocumentTitle.resolve(metadataTitle: "Untitled", fileName: "merck.pdf") == "merck")
        #expect(DocumentTitle.resolve(metadataTitle: "merck.pdf", fileName: "merck.pdf") == "merck")
    }
}
