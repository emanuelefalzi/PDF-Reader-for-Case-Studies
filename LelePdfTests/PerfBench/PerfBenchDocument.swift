import Foundation
@preconcurrency import PDFKit
@testable import LelePdf

/// A realistic "analyzed" document for the F5 benchmark
/// (`PerformanceBenchmarkTests`): the REAL pipeline on a test PDF from SPEC
/// §4 (read-only, staged copy from `scripts/test.sh`), then a synthetic
/// analysis shaped like Claude's: marks on real words of the block (real
/// ranges in the clean text, hence real rectangles on the PDF), a rewrite
/// with `{{mX|…}}` markers, points and sub-points, terms shared across blocks
/// (so repetitions and linked hover really work). No calls to Claude.
@MainActor
enum PerfBenchDocument {
    struct Built {
        let model: DocumentModel
        let structure: DocumentStructure
        let analysis: AnalysisRecord
        let tocEntries: [TocEntry]
        let pipelineSeconds: Double
        let analyzedBlockCount: Int
        let markCount: Int
    }

    /// `analyzedFraction`: share of analyzed blocks (1 = all, like a document
    /// studied in full: the worst case, and the one that arises in real use
    /// after a few sessions).
    static func build(pdfURL: URL, analyzedFraction: Double, marksPerBlock: Int) async throws -> Built {
        let data = try Data(contentsOf: pdfURL)
        let fileDocument = PDFFileDocument(data: data, displayName: pdfURL.lastPathComponent)
        guard let model = DocumentModel(document: fileDocument, fileURL: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let pipeline = await PipelineRealDocumentHelper.run(model.pdfDocument)
        let output = pipeline.output
        let structure = DocumentStructure(
            fingerprint: "bench-\(pdfURL.lastPathComponent)",
            pageCount: model.pdfDocument.pageCount,
            headings: output.headings,
            tocCandidates: output.tocCandidates,
            exhibits: output.exhibits,
            blocks: output.blocks,
            textlessPages: false,
            removedHeaderFooterLines: output.removedHeaderFooterLines,
            paragraphs: output.paragraphs
        )
        // Before mounting `PDFKitView`: `PipelineRunner.run` only starts from
        // `.idle`, and here the structure is already ready: the real pipeline
        // must not run in the background during the measurements.
        model.structure = structure
        model.pipelineState = .ready

        let tocEntries = output.tocCandidates.enumerated().map { index, candidate in
            TocEntry(
                id: "gen-\(index)", title: candidate.title, level: max(1, min(3, candidate.levelHint)), page: candidate.page,
                pageY: TocHeadingMatch.pageY(forTitle: candidate.title, pageIndex: candidate.page, headings: output.headings)
            )
        }
        model.tocEntries = tocEntries
        model.tocSource = .generated

        let (analysis, markCount) = makeAnalysis(blocks: output.blocks, analyzedFraction: analyzedFraction, marksPerBlock: marksPerBlock)
        model.analysis = analysis
        model.analysisController.updateContext(
            fingerprint: structure.fingerprint, documentTitle: fileDocument.displayName, blocks: output.blocks,
            exhibits: output.exhibits, analysis: analysis,
            lastAnalyzedBlockId: analysis.blocks.keys.sorted().last, tocEntries: tocEntries
        )
        return Built(
            model: model, structure: structure, analysis: analysis, tocEntries: tocEntries,
            pipelineSeconds: pipeline.elapsed, analyzedBlockCount: analysis.blocks.count, markCount: markCount
        )
    }

    // MARK: - Synthetic analysis shaped like the real one

    private struct Word {
        let text: String
        let start: Int // in Characters of cleanText
        let length: Int
    }

    /// "Interesting" words (≥ 6 letters) with their position in `Character`s
    /// of `cleanText`, the same unit as `MarkRange`.
    private static func candidateWords(in cleanText: String) -> [Word] {
        var words: [Word] = []
        var current = ""
        var start = 0
        var offset = 0
        for character in cleanText {
            if character.isLetter {
                if current.isEmpty { start = offset }
                current.append(character)
            } else if !current.isEmpty {
                if current.count >= 6 { words.append(Word(text: current, start: start, length: current.count)) }
                current = ""
            }
            offset += 1
        }
        if current.count >= 6 { words.append(Word(text: current, start: start, length: current.count)) }
        return words
    }

    private static func makeAnalysis(blocks: [TextBlock], analyzedFraction: Double, marksPerBlock: Int) -> (AnalysisRecord, Int) {
        var record = AnalysisRecord()
        var totalMarks = 0
        let types: [MarkType] = [.rectangle, .circle, .underline, .arrow, .rectangle, .underline]
        let analyzedCount = max(1, Int((Double(blocks.count) * analyzedFraction).rounded()))
        for (blockIndex, block) in blocks.prefix(analyzedCount).enumerated() {
            let words = candidateWords(in: block.cleanText)
            guard !words.isEmpty else { continue }
            // Words spread along the whole block (not just the first ones),
            // deduplicated by text: one mark per chosen occurrence.
            var chosen: [Word] = []
            var seen: Set<String> = []
            let stride = max(1, words.count / max(1, marksPerBlock))
            var index = 0
            while index < words.count, chosen.count < marksPerBlock {
                let word = words[index]
                let key = word.text.lowercased()
                if !seen.contains(key) { seen.insert(key); chosen.append(word) }
                index += stride
            }
            var marks: [Mark] = []
            for (markIndex, word) in chosen.enumerated() {
                let termId = "t-\(word.text.lowercased())"
                let type = types[markIndex % types.count]
                marks.append(Mark(
                    id: "m\(markIndex + 1)", termId: termId, type: type, text: word.text, source: .claude,
                    page: block.pageStart, range: MarkRange(start: word.start, length: word.length)
                ))
                if record.terms[termId] == nil {
                    record.terms[termId] = TermRecord(term: word.text, type: type, firstBlockId: block.id)
                }
            }
            totalMarks += marks.count
            record.blocks[block.id] = BlockAnalysis(
                status: .analyzed, analyzedAt: Date(), model: "bench", title: "Sezione \(blockIndex + 1)",
                rewrite: makeRewrite(block: block, marks: marks), marks: marks, links: []
            )
        }
        return (record, totalMarks)
    }

    /// Summary + paragraph + list with sub-points (SPEC §5.6), with the
    /// `{{mX|…}}` markers of the marks above inside the text: the same shape
    /// as Claude's real responses, text taken from the block itself.
    private static func makeRewrite(block: TextBlock, marks: [Mark]) -> [RewriteItem] {
        let sentences = block.cleanText.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 20 }
        func marker(_ index: Int) -> String {
            guard marks.indices.contains(index) else { return "" }
            return "{{\(marks[index].id)|\(marks[index].text)}}"
        }
        func sentence(_ index: Int) -> String {
            guard !sentences.isEmpty else { return "Testo del blocco." }
            return String(sentences[index % sentences.count].prefix(160))
        }
        let summary = "\(marker(0)) e \(marker(1)): \(sentence(0))."
        let paragraph = "\(sentence(1)). \(marker(2)) porta a \(marker(3)); \(sentence(2)). \(marker(4)) resta centrale, insieme a \(marker(5))."
        let items = (0 ..< 4).map { i in "\(marker(i + 6).isEmpty ? marker(i) : marker(i + 6)): \(sentence(i + 3).prefix(90))" }
        let subItems = (0 ..< 4).map { i in ["→ \(sentence(i + 7).prefix(70))", "\(marker(i + 10).isEmpty ? marker(i + 1) : marker(i + 10)) \(sentence(i + 8).prefix(60))"] }
        return [
            RewriteItem(kind: .summary, text: summary),
            RewriteItem(kind: .paragraph, text: paragraph),
            RewriteItem(kind: .bullets, items: items, subItems: subItems),
        ]
    }
}
