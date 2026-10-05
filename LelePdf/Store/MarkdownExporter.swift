import Foundation

/// Generates `riscrittura.md` (SPEC §8), an export for Obsidian that is
/// never reread: the JSON files remain the source of truth. A pure function,
/// testable without actors or a file system: it uses only
/// `DocumentRecord`/`AnalysisRecord`, which together already hold all the
/// structure (contents, `sectionPath` and pages of the blocks, Exhibits), so
/// there is no need to also pass the pipeline's `DocumentStructure`.
enum MarkdownExporter {
    private static let markerPattern = #"\{\{(m[^|}]+)\|([^}]*)\}\}"#

    /// [M7-7]: if the document has a visible contents outline
    /// (native/generated/manual; T1 ##, T2 ###, T3 ####, T4 #####, block
    /// titles one level below the deepest), the export uses THAT for the
    /// headings instead of `sectionPath` (derived from the pipeline,
    /// independent of the outline shown in the sidebar): `renderWithToc`.
    /// Without an outline, the behavior stays that of M3
    /// (`renderLegacyBody`) so as not to break the export of a document with
    /// no generated outline; the distinction is documented because SPEC §8
    /// itself did not separate the two sources before the manual outline.
    /// `annotations` [M7b, SPEC §5.13 "Export"]: optional with an empty
    /// default so as not to break existing calls (M3-M7) that have no
    /// annotations to export yet; see `MarkdownExporter+Annotations.swift`
    /// for the "Annotations · p. N" section at the end of each chapter.
    static func render(document: DocumentRecord, analysis: AnalysisRecord, annotations: AnnotationsRecord = AnnotationsRecord()) -> String {
        var out = frontmatter(for: document)
        out += "# \(document.title)\n"
        let visibleToc = ManualToc.visible(document.toc.entries)
        out += visibleToc.isEmpty
            ? renderLegacyBody(document: document, analysis: analysis, annotations: annotations)
            : renderWithToc(document: document, analysis: analysis, tocEntries: visibleToc, annotations: annotations)
        return out
    }

    /// Pages with exportable annotations not yet written, in order (SPEC
    /// §5.13 "a section at the end of the chapter"): `flush(before:)` writes
    /// those left behind relative to the page of the next chapter/heading,
    /// shared by `renderLegacyBody`/`renderWithToc`. Not `private`: also
    /// reused by `MarkdownExporter+Toc.swift` (same type, separate file to
    /// keep files small).
    struct AnnotationFlusher {
        let sections: [Int: String]
        var pendingPages: [Int]

        init(_ record: AnnotationsRecord, headingPrefix: String) {
            sections = AnnotationMarkdown.sectionsByPage(record, headingPrefix: headingPrefix)
            pendingPages = sections.keys.sorted()
        }

        mutating func flush(before page: Int?) -> String {
            var out = ""
            while let next = pendingPages.first, page == nil || next < page! {
                out += sections[next] ?? ""
                pendingPages.removeFirst()
            }
            return out
        }
    }

    private static func renderLegacyBody(document: DocumentRecord, analysis: AnalysisRecord, annotations: AnnotationsRecord) -> String {
        var out = ""
        var lastChapter: String?
        var lastSection: String?
        var flusher = AnnotationFlusher(annotations, headingPrefix: "####")

        for item in orderedItems(document: document) {
            switch item {
            case let .block(block):
                let sectionPath = block.sectionPath
                let chapter = sectionPath.first
                let section = sectionPath.count > 1 ? sectionPath[1] : nil
                if let chapter, chapter != lastChapter {
                    out += flusher.flush(before: block.pageStart)
                    out += "\n## \(chapter)\n"
                    lastChapter = chapter
                    lastSection = nil
                }
                if let section, section != lastSection {
                    out += "\n### \(section)\n"
                    lastSection = section
                }
                guard let blockAnalysis = analysis.blocks[block.id], blockAnalysis.status == .analyzed else {
                    // Block not analyzed: omitted (SPEC M3 item 3 leaves room
                    // for this choice).
                    continue
                }
                out += renderBlock(block, analysis: blockAnalysis, terms: analysis.terms)
            case let .exhibit(exhibit):
                out += "\n*\(exhibit.label), p. \(exhibit.page + 1)*\n"
            }
        }
        out += flusher.flush(before: nil)
        return out
    }

    // MARK: - Ordering

    private enum OrderedItem {
        case block(BlockRecord)
        case exhibit(ExhibitRecord)

        var page: Int {
            switch self {
            case let .block(block): block.pageStart
            case let .exhibit(exhibit): exhibit.page
            }
        }
    }

    /// Blocks and Exhibits interleaved "in document order" (SPEC §8): by
    /// page, first the blocks, then that page's Exhibits.
    private static func orderedItems(document: DocumentRecord) -> [OrderedItem] {
        let items: [OrderedItem] = document.blocks.map(OrderedItem.block) + document.exhibits.map(OrderedItem.exhibit)
        return items.enumerated().sorted { lhs, rhs in
            if lhs.element.page != rhs.element.page { return lhs.element.page < rhs.element.page }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - Frontmatter

    private static func frontmatter(for document: DocumentRecord) -> String {
        let formatter = ISO8601DateFormatter()
        return """
        ---
        title: \(yaml(document.title))
        source: \(yaml(document.fileName))
        pages: \(document.pageCount)
        fingerprint: \(document.fingerprint)
        updated: \(formatter.string(from: document.updatedAt))
        tags: [lelepdf]
        ---

        """
    }

    private static func yaml(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    // MARK: - Block

    private static func renderBlock(_ block: BlockRecord, analysis: BlockAnalysis, terms: [String: TermRecord]) -> String {
        let title = analysis.title ?? "Block"
        var out = "\n#### \(title) · p. \(block.pageStart + 1)\n\n"
        for item in analysis.rewrite {
            out += renderRewriteItem(item, marks: analysis.marks)
        }
        out += obsidianComment(blockId: block.id, marks: analysis.marks, terms: terms)
        return out
    }

    /// Not `private`: also reused by `MarkdownExporter+Toc.swift`.
    static func renderRewriteItem(_ item: RewriteItem, marks: [Mark]) -> String {
        switch item.kind {
        case .summary, .paragraph:
            return substituteMarkers(item.text ?? "", marks: marks) + "\n\n"
        case .definition:
            return "> **Definition:** " + substituteMarkers(item.text ?? "", marks: marks) + "\n\n"
        case .bullets:
            // Sub-points as a nested Markdown list (two spaces of
            // indentation, standard syntax recognized by Word/Obsidian; see
            // SPEC §8.1 "copy with formatting ... pasteable into
            // Word/Obsidian keeping points and sub-points").
            let items = item.items ?? []
            let subItems = item.subItems ?? []
            let lines = items.enumerated().flatMap { index, text -> [String] in
                var rows = ["- " + substituteMarkers(text, marks: marks)]
                if index < subItems.count {
                    rows.append(contentsOf: subItems[index].map { "  - " + substituteMarkers($0, marks: marks) })
                }
                return rows
            }
            return lines.joined(separator: "\n") + "\n\n"
        case .steps:
            let lines = (item.items ?? []).enumerated().map { index, text in
                "\(index + 1). " + substituteMarkers(text, marks: marks)
            }
            return lines.joined(separator: "\n") + "\n\n"
        case .table:
            return renderTable(columns: item.columns ?? [], rows: item.rows ?? [], marks: marks)
        case .callout:
            return "> [!note]\n> " + substituteMarkers(item.text ?? "", marks: marks) + "\n\n"
        case .outline:
            // The same reading of an old `kind == .bullets` or a new
            // `kind == .outline` (`RewriteOutlineReader`), the same Markdown
            // convention as `RewriteCopyExporter.outlinePlainLine` (SPEC §8
            // "consistent between Obsidian and Copy with formatting").
            let lines = RewriteOutlineReader.lines(for: item).map { line -> String in
                let text = substituteMarkers(line.text, marks: marks)
                switch line.type {
                case .point, .other: return "- " + text
                case .subpoint: return "  - " + text
                case .explanation: return "  *" + text + "*"
                case .consequence: return "- → " + text
                case .note: return "> [!note] " + text
                case .formula: return "> " + text
                case .subheading: return "\n**" + text + "**"
                case .definition: return "> [!info] " + text
                case .example: return "> [!example] " + text
                }
            }
            return lines.joined(separator: "\n") + "\n\n"
        }
    }

    private static func renderTable(columns: [String], rows: [[String]], marks: [Mark]) -> String {
        guard !columns.isEmpty else { return "" }
        var out = "| " + columns.joined(separator: " | ") + " |\n"
        out += "|" + columns.map { _ in " --- " }.joined(separator: "|") + "|\n"
        for row in rows {
            out += "| " + row.map { substituteMarkers($0, marks: marks) }.joined(separator: " | ") + " |\n"
        }
        return out + "\n"
    }

    // MARK: - Markers {{mX|shown words}} → marks (SPEC §8)

    private static func substituteMarkers(_ text: String, marks: [Mark]) -> String {
        guard text.contains("{{") else { return text }
        let marksById = Dictionary(marks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = ""
        var remaining = Substring(text)
        while let range = remaining.range(of: markerPattern, options: .regularExpression) {
            result += remaining[remaining.startIndex ..< range.lowerBound]
            let token = String(remaining[range])
            result += renderMarkerToken(token, marksById: marksById)
            remaining = remaining[range.upperBound...]
        }
        result += remaining
        return result
    }

    private static func renderMarkerToken(_ token: String, marksById: [String: Mark]) -> String {
        // token is "{{mX|shown words}}".
        let inner = token.dropFirst(2).dropLast(2)
        guard let barIndex = inner.firstIndex(of: "|") else { return String(inner) }
        let id = String(inner[inner.startIndex ..< barIndex])
        let shown = String(inner[inner.index(after: barIndex)...])

        guard let mark = marksById[id], !mark.hidden else { return shown }
        switch mark.type {
        case .rectangle: return "==\(shown)=="
        case .circle: return "**\(shown)**"
        case .underline: return "<u>\(shown)</u>"
        case .arrow: return "<u>\(shown)</u> →"
        }
    }

    // MARK: - Obsidian comment (SPEC §8)

    private struct CommentMark: Codable {
        var termId: String
        var term: String
        var type: String
    }

    private struct Comment: Codable {
        var block: String
        var marks: [CommentMark]
    }

    /// Not `private`: also reused by `MarkdownExporter+Toc.swift`.
    static func obsidianComment(blockId: String, marks: [Mark], terms: [String: TermRecord]) -> String {
        // A hidden mark was removed by the user: besides losing its
        // formatting in the text, it must not remain as an active mark in the
        // metadata meant for a future second brain.
        let commentMarks = marks.filter { !$0.hidden }.map { mark in
            CommentMark(termId: mark.termId, term: terms[mark.termId]?.term ?? mark.text, type: mark.type.rawValue)
        }
        let comment = Comment(block: blockId, marks: commentMarks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(comment), let json = String(data: data, encoding: .utf8) else {
            return "\n"
        }
        return "%% lelepdf: \(json) %%\n"
    }
}
