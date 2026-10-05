import Foundation
import Testing
@testable import LelePdf

/// Automatic checks for the format quality criteria ON ALREADY SAVED
/// ANALYSES: not on a response that has just arrived from Claude, but on the
/// same shape (`RewriteItem` inside `AnalysisRecord`) after a real
/// `JSONEncoder`/`JSONDecoder` round trip (exactly what happens when writing
/// and rereading `analisi.json` through `DocumentStore`), so a regression in
/// the encoded shape (for example `subItems` not surviving encoding) would be
/// caught here. No call to Claude; always part of the normal suite.
@Suite("Rewrite format · automatic checks on saved analyses")
struct RewriteFormatQualityTests {
    // MARK: - RewriteFormatQuality, on pure data (no encoding)

    @Test("percentage in bullets: only points and sub-points count, not the summary")
    func bulletsShareCountsOnlyBulletsKind() {
        let rewrite = [
            RewriteItem(kind: .summary, text: "Una due tre quattro cinque."), // 5 words, does not count
            RewriteItem(kind: .bullets, items: ["uno due tre", "quattro cinque sei sette"], subItems: [["otto nove"], []]),
        ]
        // bullets: "uno due tre" (3) + "quattro cinque sei sette" (4) + "otto nove" (2) = 9
        // summary: 5 words. Total 14. Bullets percentage = 9/14 = 64%.
        let report = RewriteFormatQuality.evaluate(rewrite)
        #expect(report.bulletsSharePercent == 64)
        #expect(report.mainBulletCount == 2)
        #expect(report.maxDepth == 2)
        #expect(report.meetsBulletsShareGoal == false)
    }

    @Test("depth 1 when no point has sub-points (older analyses)")
    func depthIsOneWithoutSubItems() {
        let rewrite = [RewriteItem(kind: .bullets, items: ["uno", "due", "tre"])]
        let report = RewriteFormatQuality.evaluate(rewrite)
        #expect(report.maxDepth == 1)
        #expect(report.bulletsSharePercent == 100)
    }

    @Test("paragraph coverage: one point per paragraph meets the criterion, with a tolerance of 1")
    func paragraphCoverageTolerance() {
        #expect(RewriteFormatQuality.coversEveryParagraph(mainBulletCount: 4, paragraphCount: 4))
        #expect(RewriteFormatQuality.coversEveryParagraph(mainBulletCount: 3, paragraphCount: 4)) // tolerance of 1
        #expect(!RewriteFormatQuality.coversEveryParagraph(mainBulletCount: 2, paragraphCount: 4))
    }

    @Test("overlong points (more than one idea) detected at both the main level and in sub-points")
    func overlongBulletsDetectedAtBothLevels() {
        let longSub = Array(repeating: "parola", count: 30).joined(separator: " ")
        let rewrite = [RewriteItem(kind: .bullets, items: ["punto breve"], subItems: [[longSub]])]
        let overlong = RewriteFormatQuality.overlongBullets(rewrite)
        #expect(overlong.count == 1)
        #expect(overlong.first?.words == 30)
    }

    // MARK: - On the shape actually SAVED (JSONEncoder/JSONDecoder round trip, as for analisi.json)

    /// Builds an `AnalysisRecord` with a "paragraph by paragraph" block (3
    /// paragraphs, 3 main points with sub-points, mirroring the prompt), runs
    /// it through a real JSON encode/decode, and verifies that the DECODED
    /// result still meets the criteria, not the object just built in memory.
    @Test("an analysis with points/sub-points, saved and reread, meets the mandatory quality criteria")
    func storedAnalysisMeetsQualityCriteria() throws {
        var record = AnalysisRecord()
        record.blocks["b1"] = BlockAnalysis(
            status: .analyzed, title: "Ritiro del Vioxx",
            rewrite: [
                RewriteItem(kind: .summary, text: "Il Vioxx viene approvato e poi ritirato dal mercato."),
                RewriteItem(
                    kind: .bullets,
                    items: [
                        "Il Vioxx viene approvato dalla FDA nel 1999.",
                        "Gli studi post-marketing rilevano un rischio cardiovascolare.",
                        "Merck ritira il farmaco nel settembre 2004.",
                    ],
                    subItems: [
                        ["Sostituisce i FANS più vecchi per pazienti a rischio gastrointestinale.", "Le vendite superano i 2,5 miliardi di dollari annui."],
                        ["Lo studio VIGOR mostra un rischio quattro volte superiore.", "La FDA richiede un'avvertenza nel 2002."],
                        [],
                    ]
                ),
            ]
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AnalysisRecord.self, from: data)
        let rewrite = try #require(decoded.blocks["b1"]?.rewrite)

        // 3 original paragraphs (one per main point, per the analysis prompt:
        // "the number of main bullets equals the number of paragraphs").
        let report = RewriteFormatQuality.evaluate(rewrite, paragraphCount: 3)
        #expect(report.mainBulletCount == 3)
        #expect(report.meetsParagraphCoverage == true)
        #expect(report.meetsBulletsShareGoal, "only \(report.bulletsSharePercent)% of the saved content is in bullet points (criterion: >=80%)")
        #expect(report.maxDepth == 2, "the sub-points did not survive JSON encoding/decoding")
        #expect(report.overlongBulletCount == 0)

        // Backward compatibility in the same pass: a `RewriteItem` without
        // `subItems` (an analysis saved by an older version) stays valid and at
        // depth 1 after the same encode/decode.
        var oldStyleRecord = AnalysisRecord()
        oldStyleRecord.blocks["old"] = BlockAnalysis(
            status: .analyzed, title: "Blocco pre-F4C",
            rewrite: [RewriteItem(kind: .bullets, items: ["uno", "due", "tre"])]
        )
        let oldData = try JSONEncoder().encode(oldStyleRecord)
        let oldDecoded = try JSONDecoder().decode(AnalysisRecord.self, from: oldData)
        let oldRewrite = try #require(oldDecoded.blocks["old"]?.rewrite)
        #expect(RewriteFormatQuality.evaluate(oldRewrite).maxDepth == 1)
        #expect(oldRewrite.first?.subItems == nil)
    }

    /// An `analisi.json` written literally before this change (no `subItems`
    /// key in the JSON, not just `nil` in memory): verifies the decoding
    /// backward compatibility ("keeping backward compatibility when decoding
    /// existing analisi.json") on a hand-written JSON fragment rather than one
    /// produced by this same version of the app.
    @Test("a bullets JSON without the subItems key (older format) decodes correctly")
    func decodesPreF4CJSONWithoutSubItemsKey() throws {
        let json = """
        { "kind": "bullets", "items": ["uno", "due", "tre"] }
        """
        let item = try JSONDecoder().decode(RewriteItem.self, from: Data(json.utf8))
        #expect(item.subItems == nil)
        #expect(item.items == ["uno", "due", "tre"])
        #expect(RewriteFormatQuality.evaluate([item]).maxDepth == 1)
    }
}
