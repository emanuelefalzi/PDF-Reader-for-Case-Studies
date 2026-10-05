import Foundation

/// Export, reworked after a real export came out badly formatted and
/// off-template: it exports ONLY the simplified rewrite, in three ways (copy
/// with formatting, PDF, Word). This file is the pure model, independent of
/// the target format: `RewriteExportModel.build` turns `DocumentRecord` +
/// `AnalysisRecord` into a sequence of nodes (`RewriteExportNode`) that the
/// three exporters (`RewriteExportAttributedString`, `RewritePDFExporter`,
/// `RewriteDocxExporter`) read the same way: a single source of truth for
/// "structure preserved in all three formats" (§8.2, the same structure in
/// all three).
///
/// It does not reuse `MarkdownExporter` (which produces Markdown text for
/// Obsidian, SPEC §8, and ALSO shows the card title as a heading, a choice of
/// ITS OWN: block titles one level below the deepest used). Here a structured
/// model (not text) is needed, and the two exports stay independent. It does
/// reuse `RewriteResolution.resolveSegments` (already used by the real panel
/// and the Summary Lab) to resolve the `{{mX|...}}` markers, so the marks
/// recognized here are exactly the ones shown on screen, and
/// `ManualToc`/`TocEntryRecord` (already used by `MarkdownExporter+Toc`) for
/// the headings.
enum RewriteExportScope: String, Sendable, Equatable, CaseIterable {
    case wholeDocument
    case currentSection
}

/// A run of text, with or without a mark (SPEC §5.4): `emphasis` flags a
/// marked term of any type, not "bold" in itself. By default NO visible
/// formatting derives from it in any of the three formats (no `<w:b/>` in
/// Word); the "Emphasise marked terms" option (off by default,
/// `WordTemplateSettings`) decides whether an exporter renders it visibly.
/// `RewriteExportModel` stays pure with respect to this preference: a single
/// model, read the same way regardless of how each exporter will use it.
struct RewriteExportRun: Sendable, Equatable {
    var text: String
    var emphasis: Bool = false
}

/// High-level node, in document order (or of the section alone, SPEC §8.3),
/// ALWAYS traceable to a Word style of the user's vocabulary (never
/// "Normal"). There is no `.blockTitle` (the card title written by Claude is
/// never exported as a heading) and no `.paragraph`/`.definition`/`.callout`
/// (an old pre-outline `kind` immediately becomes, in the model, an
/// `outlineLine`, never a separate node that an exporter would then have to
/// reduce to "Normal" on its own).
enum RewriteExportNode: Sendable, Equatable {
    case heading(text: String, level: Int)
    case steps([[RewriteExportRun]])
    case table(columns: [String], rows: [[[RewriteExportRun]]])
    case exhibit(String)
    /// One line of the rewrite in the user's Word style: one node per line,
    /// each line becoming its own OOXML paragraph with its own `w:pStyle`
    /// (`RewriteDocxExporter`). Produced both by a `kind == .outline` and,
    /// for backward compatibility, by an old `kind == .bullets`/`.summary`/
    /// `.paragraph`/`.definition`/`.callout`, so an analysis saved before the
    /// outline format still exports to a Word style of the mapping table,
    /// never "Normal".
    case outlineLine(RewriteLineType, [RewriteExportRun])
}

/// Document ready for export. `Header` is still computed (title for the
/// suggested file name, `RewriteExportController.fileName`; section/pages for
/// the future) but NO exporter writes it into the body any more: there is no
/// generated "Title · Section · pages" header ("Chapter is not used ... at
/// most nothing").
struct RewriteExportDocument: Sendable, Equatable {
    struct Header: Sendable, Equatable {
        var documentTitle: String
        var sectionLabel: String
        var pagesLabel: String
    }

    var header: Header
    var nodes: [RewriteExportNode]
}

enum RewriteExportModel {
    /// `currentBlockId`: the block at the current reading position
    /// (`DocumentModel.currentFocusedBlockId`), used to resolve the "current
    /// section" scope (SPEC §8.3; only the SOURCE of the headings changed, not
    /// which blocks are included). Pure: no dependency on
    /// `DocumentModel`/AppKit, testable with the `analisi.json`/
    /// `documento.json` fixtures alone (`StoreFixtures`). `orphans`: saved
    /// analyses no longer attached to any block of the current segmentation
    /// (SPEC §7.3, `DocumentModel.orphanBlocks`), so they stay exportable
    /// until replaced. Included ONLY in the "whole document" scope (they no
    /// longer have a `sectionPath`, so they would not meaningfully belong to
    /// any "current section"), at the end, under a dedicated heading that
    /// makes them recognizable in the export. Defaults to `[]`: callers/tests
    /// that do not pass them behave exactly as before.
    static func build(document: DocumentRecord, analysis: AnalysisRecord, scope: RewriteExportScope, currentBlockId: String?, orphans: [OrphanBlock] = []) -> RewriteExportDocument {
        let allBlocks = document.blocks
        let included: [BlockRecord]
        let sectionLabel: String

        switch scope {
        case .wholeDocument:
            included = allBlocks
            sectionLabel = "Whole Document"
        case .currentSection:
            // "Section" = the same `sectionPath` as the block at the reading
            // position, not the T1-T4 index (a different source, never
            // reconciled with `sectionPath`). A document split into "part 1 of
            // N" remains a single `sectionPath`: all the parts stay included.
            let currentPath = allBlocks.first { $0.id == currentBlockId }?.sectionPath ?? allBlocks.first?.sectionPath ?? []
            included = allBlocks.filter { $0.sectionPath == currentPath }
            sectionLabel = currentPath.isEmpty ? "Current Section" : currentPath.joined(separator: " › ")
        }

        let minPage = included.map(\.pageStart).min()
        let maxPage = included.map(\.pageEnd).max()
        let includedExhibits = exhibits(for: scope, document: document, minPage: minPage, maxPage: maxPage)
        // Headings come ONLY from the document's contents
        // (T1-T4, `document.toc.entries`), never from `sectionPath`: the same
        // source `MarkdownExporter+Toc` already uses, for the same reason.
        let includedTocEntries = tocEntries(for: scope, document: document, minPage: minPage, maxPage: maxPage)
        var resultNodes = nodes(blocks: included, exhibits: includedExhibits, tocEntries: includedTocEntries, analysis: analysis)
        if scope == .wholeDocument, !orphans.isEmpty {
            resultNodes.append(contentsOf: orphanNodes(orphans, analysis: analysis))
        }

        return RewriteExportDocument(
            header: Header(documentTitle: document.title, sectionLabel: sectionLabel, pagesLabel: pagesLabel(minPage: minPage, maxPage: maxPage)),
            nodes: resultNodes
        )
    }

    /// The orphans at the end, under a dedicated T4 heading (never level 1-3:
    /// they are not part of the real hierarchy of the contents), in ascending
    /// page order, each with its own card subheading and its own text, rendered
    /// like a normal block (`nodes(for:marksById:)`). Markers still resolve
    /// because `blockAnalysis.marks` stays intact for an orphan analysis (never
    /// deleted, only detached).
    private static func orphanNodes(_ orphans: [OrphanBlock], analysis: AnalysisRecord) -> [RewriteExportNode] {
        let analyzedOrphans = orphans
            .filter { analysis.blocks[$0.blockId]?.status == .analyzed || analysis.blocks[$0.blockId]?.status == .orphan }
            .sorted { $0.page < $1.page }
        guard !analyzedOrphans.isEmpty else { return [] }
        var result: [RewriteExportNode] = [.heading(text: "Saved analyses (previous blocks)", level: 4)]
        for orphan in analyzedOrphans {
            guard let blockAnalysis = analysis.blocks[orphan.blockId] else { continue }
            let marksById = Dictionary(blockAnalysis.marks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            result.append(.outlineLine(.subheading, [RewriteExportRun(text: "\(blockAnalysis.title ?? "Block") -- p. \(orphan.page + 1)")]))
            for rewriteItem in blockAnalysis.rewrite {
                result.append(contentsOf: nodes(for: rewriteItem, marksById: marksById))
            }
        }
        return result
    }

    private typealias Header = RewriteExportDocument.Header

    private static func exhibits(for scope: RewriteExportScope, document: DocumentRecord, minPage: Int?, maxPage: Int?) -> [ExhibitRecord] {
        switch scope {
        case .wholeDocument:
            return document.exhibits
        case .currentSection:
            guard let minPage, let maxPage else { return [] }
            return document.exhibits.filter { $0.page >= minPage && $0.page <= maxPage }
        }
    }

    /// VISIBLE entries of the contents (`ManualToc.visible`, removal tombstones
    /// excluded, the same rule as `MarkdownExporter.render`), in the same
    /// position order within the document (`ManualToc.sorted`). "Current
    /// section": only the entries whose page falls within the range of the
    /// included blocks, the same idea as `exhibits(for:...)` above, not a new
    /// notion.
    private static func tocEntries(for scope: RewriteExportScope, document: DocumentRecord, minPage: Int?, maxPage: Int?) -> [TocEntryRecord] {
        let visible = ManualToc.visible(document.toc.entries)
        switch scope {
        case .wholeDocument:
            return ManualToc.sorted(visible)
        case .currentSection:
            guard let minPage, let maxPage else { return [] }
            return ManualToc.sorted(visible.filter { $0.page >= minPage && $0.page <= maxPage })
        }
    }

    private static func pagesLabel(minPage: Int?, maxPage: Int?) -> String {
        guard let minPage, let maxPage else { return "—" }
        return maxPage > minPage ? "p. \(minPage + 1)-\(maxPage + 1)" : "p. \(minPage + 1)"
    }

    // MARK: - Ordering and nodes

    /// Headings, blocks and Exhibits interleaved "in document order" (SPEC §8,
    /// "in order, before the content that belongs to them"): the same
    /// convention as `MarkdownExporter+Toc.tocOrderedItems`: by page, then
    /// priority (heading, block, Exhibit), then arrival order. A block with no
    /// contents heading above it (no entry between the last emitted heading
    /// and itself) simply continues under the previous one. This is a direct
    /// consequence of the interleaving, not a separate rule: there is no longer
    /// a card title to stand in for it.
    private enum OrderedItem {
        case heading(TocEntryRecord)
        case block(BlockRecord)
        case exhibit(ExhibitRecord)

        var page: Int {
            switch self {
            case let .heading(entry): entry.page
            case let .block(block): block.pageStart
            case let .exhibit(exhibit): exhibit.page
            }
        }

        var priority: Int {
            switch self {
            case .heading: 0
            case .block: 1
            case .exhibit: 2
            }
        }
    }

    private static func nodes(blocks: [BlockRecord], exhibits: [ExhibitRecord], tocEntries: [TocEntryRecord], analysis: AnalysisRecord) -> [RewriteExportNode] {
        let items: [OrderedItem] = tocEntries.map(OrderedItem.heading) + blocks.map(OrderedItem.block) + exhibits.map(OrderedItem.exhibit)
        let ordered = items.enumerated().sorted { lhs, rhs in
            if lhs.element.page != rhs.element.page { return lhs.element.page < rhs.element.page }
            if lhs.element.priority != rhs.element.priority { return lhs.element.priority < rhs.element.priority }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var result: [RewriteExportNode] = []
        for item in ordered {
            switch item {
            case let .heading(entry):
                result.append(.heading(text: entry.title, level: entry.level))
            case let .block(block):
                guard let blockAnalysis = analysis.blocks[block.id], blockAnalysis.status == .analyzed else { continue }
                let marksById = Dictionary(blockAnalysis.marks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for rewriteItem in blockAnalysis.rewrite {
                    result.append(contentsOf: nodes(for: rewriteItem, marksById: marksById))
                }
            case let .exhibit(exhibit):
                result.append(.exhibit("\(exhibit.label), p. \(exhibit.page + 1)"))
            }
        }
        return result
    }

    /// Subject + verb of a pre-outline summary that TALKS ABOUT the block/
    /// section instead of summarizing its content ("'The block traces…'-style
    /// meta-summaries"). A real example found in Ockham's `analisi.json`: "The
    /// block traces {{t1|Triandiflou}}'s family background...". The other 3
    /// `summary` lines of the same file, written in the first person or about
    /// the content ("While writing the business plan...", "Jim Triandiflou,
    /// CEO..."), do NOT start like that and are kept.
    private static let metaSummarySubjects = ["the block", "this block", "the section", "this section", "the chapter", "this chapter", "the document", "this document"]
    private static let metaSummaryVerbs = [
        "traces", "discusses", "discuss", "describes", "describe", "covers", "cover", "explains", "explain",
        "summarizes", "summarize", "summarises", "summarise", "outlines", "outline", "reviews", "review",
        "examines", "examine", "recounts", "recount", "follows", "follow", "narrates", "narrate", "presents", "present",
    ]

    /// A declared, deterministic rule, not a case-by-case judgment. Compared
    /// against the RAW text (before resolving `{{mX|...}}`): the real example
    /// never has a marker in the first words, and a meta subject+verb does not
    /// require one.
    private static func isMetaSummary(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for subject in metaSummarySubjects {
            let prefix = subject + " "
            guard lowered.hasPrefix(prefix) else { continue }
            let rest = lowered[lowered.index(lowered.startIndex, offsetBy: prefix.count)...]
            if metaSummaryVerbs.contains(where: { rest == $0 || rest.hasPrefix($0 + " ") }) {
                return true
            }
        }
        return false
    }

    /// A `RewriteItem` ALWAYS produces one or more `.outlineLine`s (never a
    /// `.paragraph`/`.definition`/`.callout` that an exporter would then have
    /// to reduce to "Normal" on its own). An old pre-outline `kind` becomes
    /// `Spiegazionebullet` (explanatory prose, the closest reading to a plain
    /// paragraph in the mapping table), `Definizione` (`definition`) or `Nota`
    /// (an "aside" from the main thread, for `callout`), or disappears
    /// entirely if it is a meta-summary (`isMetaSummary`). `kind == .outline`/
    /// `.bullets` remain the only case with several lines, read by
    /// `RewriteOutlineReader`.
    private static func nodes(for item: RewriteItem, marksById: [String: Mark]) -> [RewriteExportNode] {
        switch item.kind {
        case .summary, .paragraph:
            let text = item.text ?? ""
            guard !isMetaSummary(text) else { return [] }
            return [.outlineLine(.explanation, runs(text, marksById: marksById))]
        case .definition:
            // An old "definition" goes into the template's `Definizione`
            // style (before: `Spiegazionebullet` with "Definition: " in front,
            // when no dedicated style existed).
            return [.outlineLine(.definition, runs(item.text ?? "", marksById: marksById))]
        case .callout:
            return [.outlineLine(.note, runs(item.text ?? "", marksById: marksById))]
        case .steps:
            return [.steps((item.items ?? []).map { runs($0, marksById: marksById) })]
        case .table:
            return [.table(columns: item.columns ?? [], rows: (item.rows ?? []).map { row in row.map { runs($0, marksById: marksById) } })]
        case .bullets, .outline:
            return RewriteOutlineReader.lines(for: item).map { line in .outlineLine(line.type, runs(line.text, marksById: marksById)) }
        }
    }

    /// `{{mX|...}}` markers -> runs (visible mark or not, SPEC §7.5), reusing
    /// `RewriteResolution` (already used by the panel and the Summary Lab): the
    /// same notion of "visible mark" (a marker with a known id that is not
    /// hidden) used by the real interface. `emphasis` here only flags "this is
    /// a mark"; whether an exporter renders it visibly depends on the
    /// "Emphasise marked terms" preference, not on this model.
    private static func runs(_ text: String, marksById: [String: Mark]) -> [RewriteExportRun] {
        guard !text.isEmpty else { return [] }
        return RewriteResolution.resolveSegments(text, marksById: marksById).map { segment in
            switch segment {
            case .plain(let plainText): RewriteExportRun(text: plainText, emphasis: false)
            case .marked(let markedText, _, _, _): RewriteExportRun(text: markedText, emphasis: true)
            }
        }
    }
}
