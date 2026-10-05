import Testing
import Foundation
@testable import LelePdf

/// Codable round trip of the model (SPEC §8, "model
/// Codable round-trip for every kind").
@Suite("AnnotationModel")
struct AnnotationModelTests {
    private func sample(kind: AnnotationKind) -> Annotation {
        Annotation(
            id: "a1", page: 3, kind: kind, color: AnnotationColor(red: 1, green: 0.9, blue: 0.25, alpha: 0.55),
            fillColor: AnnotationColor(red: 0, green: 0.4, blue: 1, alpha: 1), lineWidth: 3, dash: [4, 2],
            rect: AnnotationRect(x: 10, y: 20, width: 100, height: 40),
            textRange: AnnotationTextRange(start: 5, length: 12),
            quads: [AnnotationRect(x: 10, y: 20, width: 50, height: 10)],
            points: [AnnotationPoint(x: 1, y: 2), AnnotationPoint(x: 3, y: 4)],
            text: "Nota di prova", fontSize: 13, font: "Helvetica", alignment: "left",
            createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 2000)
        )
    }

    @Test("every kind survives a JSON round trip", arguments: AnnotationKind.allCases)
    func roundTrip(kind: AnnotationKind) throws {
        let original = sample(kind: kind)
        let data = try AtomicJSONFile.encode(original)
        let decoded = try AtomicJSONFile.decoder.decode(Annotation.self, from: data)
        #expect(decoded == original)
    }

    @Test("AnnotationsRecord with several items round-trips unchanged")
    func recordRoundTrip() throws {
        let record = AnnotationsRecord(version: 1, items: AnnotationKind.allCases.enumerated().map { index, kind in
            var item = sample(kind: kind)
            item.id = "a\(index)"
            return item
        })
        let data = try AtomicJSONFile.encode(record)
        let decoded = try AtomicJSONFile.decoder.decode(AnnotationsRecord.self, from: data)
        #expect(decoded == record)
    }

    @Test("an empty record (document without annotations) round-trips unchanged")
    func emptyRecordRoundTrip() throws {
        let record = AnnotationsRecord()
        let data = try AtomicJSONFile.encode(record)
        let decoded = try AtomicJSONFile.decoder.decode(AnnotationsRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.items.isEmpty)
        #expect(decoded.version == 1)
    }

    @Test("nextId continues from the highest existing numeric id")
    func nextIdContinuesFromMax() {
        let items = [sample(kind: .highlight), { var item = sample(kind: .note); item.id = "a5"; return item }()]
        #expect(AnnotationIdentifiers.nextId(in: items) == "a6")
        #expect(AnnotationIdentifiers.nextId(in: []) == "a1")
    }
}
