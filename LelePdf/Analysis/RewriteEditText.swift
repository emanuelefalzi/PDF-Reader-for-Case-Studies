import Foundation

/// Editable text of a card ⇄ `[RewriteItem]` (SPEC §5.6 "Edit text": "the text
/// is converted locally into the format with {{mX|...}} markers and the marks
/// are rebuilt from there"; the approach is the simplest robust one).
///
/// The whole card becomes ONE single editable text, with items separated by a
/// blank line, in the SAME order and with the same number of paragraphs as the
/// original list; it is not a free editor that adds/removes/reorders whole
/// elements (`summary`/`table`/...). Inside a paragraph the text is free;
/// `bullets`/`steps` stay "text lines" (one per element, visible prefix
/// "- "/"N. ": one more/fewer line is one more/fewer element; SPEC "edit them
/// as text lines with a documented simple format"); `table` becomes
/// "cell | cell" rows (columns are not editable here; the marks inside each
/// cell follow the edits as in the other types). If a mark is moved across the
/// separator, it is clipped to the resulting cells instead of producing
/// invalid ranges. If the number of paragraphs changes (the user altered a
/// double blank line), the mapping stops at the common minimum: extra
/// paragraphs are discarded, missing ones keep the original item unchanged.
/// A controlled degradation, never a crash.
enum RewriteEditText {
    struct MarkSpan: Equatable {
        var range: NSRange // Character units, like `Mark.range`.
        var markId: String
    }

    struct Built: Equatable {
        var text: String
        var spans: [MarkSpan]
    }

    // MARK: - Per-row editing

    /// Identifies EXACTLY one editable `RewriteItem` field: the same field the
    /// reading view draws with ONE `MarkedTextView`
    /// (`RewriteItemView`/`RewriteLineRowView`/`TableItemView`). Nothing new to
    /// invent in rendering, just a name for "that row there".
    enum LineRef: Hashable, Sendable {
        /// `summary`/`paragraph`/`definition`/`callout`: a single field per
        /// item, so "the row" is the whole `item.text`.
        case whole(itemIndex: Int)
        case bulletMain(itemIndex: Int, index: Int)
        case bulletSub(itemIndex: Int, index: Int, subIndex: Int)
        case step(itemIndex: Int, index: Int)
        case tableCell(itemIndex: Int, row: Int, col: Int)
        case outlineLine(itemIndex: Int, index: Int)
    }

    /// Raw text (`{{mX|...}}` markers included) of the field indicated by
    /// `ref`, `nil` if the index no longer exists (the card changed under our
    /// feet between opening the editor and saving; never a crash).
    private static func rawFieldText(for ref: LineRef, in items: [RewriteItem]) -> String? {
        switch ref {
        case .whole(let i):
            guard items.indices.contains(i) else { return nil }
            return items[i].text ?? ""
        case .bulletMain(let i, let idx):
            guard items.indices.contains(i), let list = items[i].items, list.indices.contains(idx) else { return nil }
            return list[idx]
        case .bulletSub(let i, let idx, let sub):
            guard items.indices.contains(i), let subItems = items[i].subItems, subItems.indices.contains(idx), subItems[idx].indices.contains(sub) else { return nil }
            return subItems[idx][sub]
        case .step(let i, let idx):
            guard items.indices.contains(i), let list = items[i].items, list.indices.contains(idx) else { return nil }
            return list[idx]
        case .tableCell(let i, let row, let col):
            guard items.indices.contains(i), let rows = items[i].rows, rows.indices.contains(row), rows[row].indices.contains(col) else { return nil }
            return rows[row][col]
        case .outlineLine(let i, let idx):
            guard items.indices.contains(i), let lines = items[i].lines, lines.indices.contains(idx) else { return nil }
            return lines[idx].text
        }
    }

    /// Plain text + mark spans of the field `ref` (markers already resolved,
    /// the same representation as the row editor); `nil` if the field no longer
    /// exists.
    static func text(for ref: LineRef, in items: [RewriteItem]) -> Built? {
        guard let raw = rawFieldText(for: ref, in: items) else { return nil }
        return renderMarkerText(raw)
    }

    /// Writes the EDITED text + spans into the field `ref` (markers rebuilt),
    /// without touching any other field/item. No effect if `ref` no longer
    /// exists (the card changed under our feet).
    static func apply(text: String, spans: [MarkSpan], to ref: LineRef, items: inout [RewriteItem]) {
        let raw = markerText(text, spans: spans)
        switch ref {
        case .whole(let i):
            guard items.indices.contains(i) else { return }
            items[i].text = raw
        case .bulletMain(let i, let idx):
            guard items.indices.contains(i), items[i].items?.indices.contains(idx) == true else { return }
            items[i].items?[idx] = raw
        case .bulletSub(let i, let idx, let sub):
            guard items.indices.contains(i), items[i].subItems?.indices.contains(idx) == true, items[i].subItems?[idx].indices.contains(sub) == true else { return }
            items[i].subItems?[idx][sub] = raw
        case .step(let i, let idx):
            guard items.indices.contains(i), items[i].items?.indices.contains(idx) == true else { return }
            items[i].items?[idx] = raw
        case .tableCell(let i, let row, let col):
            guard items.indices.contains(i), items[i].rows?.indices.contains(row) == true, items[i].rows?[row].indices.contains(col) == true else { return }
            items[i].rows?[row][col] = raw
        case .outlineLine(let i, let idx):
            guard items.indices.contains(i), items[i].lines?.indices.contains(idx) == true else { return }
            items[i].lines?[idx].text = raw
        }
    }

    /// `LineRef` of the card's FIRST editable row (the "Edit text" menu): the
    /// first item with at least one row, skipping an empty structured item
    /// (`bullets`/`steps`/`table`/`outline`) instead of opening an editor with
    /// nothing to edit. `nil` if the card has no editable row.
    static func firstLineRef(items: [RewriteItem]) -> LineRef? {
        for (i, item) in items.enumerated() {
            switch item.kind {
            case .summary, .paragraph, .definition, .callout:
                return .whole(itemIndex: i)
            case .bullets:
                if (item.items ?? []).indices.contains(0) { return .bulletMain(itemIndex: i, index: 0) }
            case .steps:
                if (item.items ?? []).indices.contains(0) { return .step(itemIndex: i, index: 0) }
            case .table:
                if let rows = item.rows, rows.indices.contains(0), rows[0].indices.contains(0) {
                    return .tableCell(itemIndex: i, row: 0, col: 0)
                }
            case .outline:
                if (item.lines ?? []).indices.contains(0) { return .outlineLine(itemIndex: i, index: 0) }
            }
        }
        return nil
    }

    static func render(items: [RewriteItem]) -> Built {
        var text = ""
        var spans: [MarkSpan] = []
        for (index, item) in items.enumerated() {
            if index > 0 { text += "\n\n" }
            appendBuilt(renderItem(item), to: &text, spans: &spans)
        }
        return Built(text: text, spans: spans)
    }

    private static func renderItem(_ item: RewriteItem) -> Built {
        switch item.kind {
        case .summary, .paragraph, .callout, .definition:
            return renderMarkerText(item.text ?? "")
        case .bullets:
            return renderLines(bulletLines(item))
        case .steps:
            return renderLines((item.items ?? []).enumerated().map { "\($0.offset + 1). " + $0.element })
        case .table:
            return renderLines((item.rows ?? []).map { $0.joined(separator: " | ") })
        case .outline:
            return renderLines((item.lines ?? []).map { outlinePrefix(for: $0.type) + $0.text })
        }
    }

    /// Visible prefix per row of "Edit text": a single textual convention per
    /// type, recognized when parsing back by `outlineLineType(forPrefixedLine:)`.
    /// `consequence` reuses "-> " (the older convention, already known to
    /// whoever edits the text by hand); the others are new, one character each
    /// to stay quick to type by hand.
    private static func outlinePrefix(for type: RewriteLineType) -> String {
        switch type {
        case .point: "- "
        case .subpoint: "  - "
        case .explanation: "  ~ "
        case .note: "! "
        case .formula: "= "
        case .consequence: "-> "
        case .subheading: "## "
        case .definition: "def: "
        case .example: "ex: "
        case .other: "- "
        }
    }

    /// Rows of a `bullets` element with subpoints ("Edit text" §5.6): a main
    /// point "- text" followed by its indented subpoints "  - text" (two
    /// spaces, the same "- " marker as the main point: distinguished only by
    /// indentation, which `isSubBulletLine`/`stripSubBulletPrefix` below
    /// recognize at parse time). A point without subpoints produces just its
    /// row, identical to the earlier behavior (no regression on data/tests
    /// without `subItems`).
    private static func bulletLines(_ item: RewriteItem) -> [String] {
        let items = item.items ?? []
        let subItems = item.subItems ?? []
        return items.enumerated().flatMap { index, text -> [String] in
            var lines = ["- " + text]
            if index < subItems.count {
                lines.append(contentsOf: subItems[index].map { "  - " + $0 })
            }
            return lines
        }
    }

    private static func renderLines(_ rawLines: [String]) -> Built {
        var text = ""
        var spans: [MarkSpan] = []
        for (index, raw) in rawLines.enumerated() {
            if index > 0 { text += "\n" }
            appendBuilt(renderMarkerText(raw), to: &text, spans: &spans)
        }
        return Built(text: text, spans: spans)
    }

    private static func appendBuilt(_ built: Built, to text: inout String, spans: inout [MarkSpan]) {
        let base = text.count
        text += built.text
        spans.append(contentsOf: built.spans.map { MarkSpan(range: NSRange(location: $0.range.location + base, length: $0.range.length), markId: $0.markId) })
    }

    private static let markerPattern = #"\{\{([^|}]+)\|([^}]*)\}\}"#

    private static func renderMarkerText(_ text: String) -> Built {
        guard text.contains("{{") else { return Built(text: text, spans: []) }
        var result = ""
        var spans: [MarkSpan] = []
        var remaining = Substring(text)
        while let range = remaining.range(of: markerPattern, options: .regularExpression) {
            result += remaining[remaining.startIndex ..< range.lowerBound]
            let inner = remaining[range].dropFirst(2).dropLast(2)
            if let barIndex = inner.firstIndex(of: "|") {
                let id = String(inner[inner.startIndex ..< barIndex])
                let shown = String(inner[inner.index(after: barIndex)...])
                spans.append(MarkSpan(range: NSRange(location: result.count, length: shown.count), markId: id))
                result += shown
            }
            remaining = remaining[range.upperBound...]
        }
        result += remaining
        return Built(text: result, spans: spans)
    }

    // MARK: - Parsing back (saving, no call to Claude)

    /// Rebuilds `[RewriteItem]` from the edited text and the spans of the marks
    /// that SURVIVED in it (read from the custom attribute of
    /// `EditableMarkedNSTextView`, which naturally follows typing/deletion;
    /// SPEC "if you rewrite them the mark follows, if you delete them the mark
    /// disappears"). `originalItems` provides the `kind`/columns of each
    /// paragraph (not re-deduced from the text).
    static func parse(text: String, spans: [MarkSpan], originalItems: [RewriteItem]) -> [RewriteItem] {
        let paragraphs = splitParagraphs(text)
        let count = min(paragraphs.count, originalItems.count)
        var result = (0 ..< count).map { parseItem(kind: originalItems[$0].kind, originalColumns: originalItems[$0].columns, paragraph: paragraphs[$0], spans: spans) }
        if originalItems.count > count {
            result.append(contentsOf: originalItems[count...])
        }
        return result
    }

    private struct Paragraph { var range: NSRange; var text: String }

    private static func splitParagraphs(_ text: String) -> [Paragraph] {
        var offset = 0
        return text.components(separatedBy: "\n\n").map { block in
            defer { offset += block.count + 2 }
            return Paragraph(range: NSRange(location: offset, length: block.count), text: block)
        }
    }

    private static func overlapping(_ spans: [MarkSpan], with range: NSRange) -> [MarkSpan] {
        spans.compactMap { span in
            let start = max(span.range.location, range.location)
            let end = min(span.range.location + span.range.length, range.location + range.length)
            guard end > start else { return nil }
            return MarkSpan(range: NSRange(location: start - range.location, length: end - start), markId: span.markId)
        }
    }

    private static func parseItem(kind: RewriteKind, originalColumns: [String]?, paragraph: Paragraph, spans: [MarkSpan]) -> RewriteItem {
        let localSpans = overlapping(spans, with: paragraph.range)
        switch kind {
        case .summary, .paragraph, .callout, .definition:
            return RewriteItem(kind: kind, text: markerText(paragraph.text, spans: localSpans))
        case .bullets:
            return parseBullets(kind: kind, paragraph: paragraph, spans: localSpans)
        case .steps:
            let lines = linesWithSpans(paragraph.text, spans: localSpans).map(stripListPrefix)
            return RewriteItem(kind: kind, items: lines.map { markerText($0.text, spans: $0.spans) })
        case .table:
            let rows = linesWithSpans(paragraph.text, spans: localSpans).map { line in
                tableCellsWithSpans(line).map { cell in
                    markerText(cell.text, spans: cell.spans)
                }
            }
            return RewriteItem(kind: kind, columns: originalColumns, rows: rows)
        case .outline:
            let rawLines = linesWithSpans(paragraph.text, spans: localSpans)
            let parsedLines = rawLines.map { line -> RewriteLine in
                let (type, stripped) = stripOutlinePrefix(line)
                return RewriteLine(type: type, text: markerText(stripped.text, spans: stripped.spans))
            }
            return RewriteItem(kind: kind, lines: parsedLines)
        }
    }

    /// Reads back the prefix written by `outlinePrefix(for:)`, with the same
    /// controlled-degradation principle as `stripListPrefix` below (an
    /// unrecognized prefix stays a plain `point`, never a discard or crash).
    private static func stripOutlinePrefix(_ line: (text: String, spans: [MarkSpan])) -> (type: RewriteLineType, text: (text: String, spans: [MarkSpan])) {
        let prefixes: [(String, RewriteLineType)] = [
            ("  - ", .subpoint), ("  ~ ", .explanation), ("-> ", .consequence),
            ("! ", .note), ("= ", .formula), ("## ", .subheading), ("def: ", .definition), ("ex: ", .example), ("- ", .point),
        ]
        for (prefix, type) in prefixes where line.text.hasPrefix(prefix) {
            let prefixLength = prefix.count
            let stripped = String(line.text.dropFirst(prefixLength))
            let adjusted: [MarkSpan] = line.spans.compactMap { span in
                let newStart = span.range.location - prefixLength
                if newStart < 0 {
                    let clippedLength = span.range.length + newStart
                    guard clippedLength > 0 else { return nil }
                    return MarkSpan(range: NSRange(location: 0, length: clippedLength), markId: span.markId)
                }
                return MarkSpan(range: NSRange(location: newStart, length: span.range.length), markId: span.markId)
            }
            return (type, (stripped, adjusted))
        }
        return (.point, line)
    }

    /// Rows of `bullets` with subpoints: an indented row (`isSubBulletLine`)
    /// becomes a subpoint of the most recently read main point; an indented row
    /// BEFORE any main point (malformed text) is discarded instead of making
    /// the parse collapse. A degradation symmetric to `RewriteEditText.parse`
    /// at the top of the file: never a crash, just a poorer structure than the
    /// one typed.
    private static func parseBullets(kind: RewriteKind, paragraph: Paragraph, spans: [MarkSpan]) -> RewriteItem {
        let rawLines = linesWithSpans(paragraph.text, spans: spans)
        var items: [String] = []
        var subItems: [[String]] = []
        for line in rawLines {
            if isSubBulletLine(line.text) {
                guard !items.isEmpty else { continue }
                let stripped = stripSubBulletPrefix(line)
                subItems[items.count - 1].append(markerText(stripped.text, spans: stripped.spans))
            } else {
                let stripped = stripListPrefix(line)
                items.append(markerText(stripped.text, spans: stripped.spans))
                subItems.append([])
            }
        }
        let hasSub = subItems.contains { !$0.isEmpty }
        return RewriteItem(kind: kind, items: items, subItems: hasSub ? subItems : nil)
    }

    private static func isSubBulletLine(_ text: String) -> Bool {
        text.range(of: #"^[ \t]+-\s"#, options: .regularExpression) != nil
    }

    private static func stripSubBulletPrefix(_ line: (text: String, spans: [MarkSpan])) -> (text: String, spans: [MarkSpan]) {
        guard let match = line.text.range(of: #"^[ \t]+-\s*"#, options: .regularExpression) else { return line }
        let prefixLength = line.text.distance(from: line.text.startIndex, to: match.upperBound)
        let stripped = String(line.text.dropFirst(prefixLength))
        let adjusted: [MarkSpan] = line.spans.compactMap { span in
            let newStart = span.range.location - prefixLength
            if newStart < 0 {
                let clippedLength = span.range.length + newStart
                guard clippedLength > 0 else { return nil }
                return MarkSpan(range: NSRange(location: 0, length: clippedLength), markId: span.markId)
            }
            return MarkSpan(range: NSRange(location: newStart, length: span.range.length), markId: span.markId)
        }
        return (stripped, adjusted)
    }

    /// Splits a table row keeping the spans in cell-local coordinates. The
    /// spaces around the separator are not part of the saved cell, so the
    /// ranges are clipped after the trim as well.
    private static func tableCellsWithSpans(
        _ line: (text: String, spans: [MarkSpan])
    ) -> [(text: String, spans: [MarkSpan])] {
        let separator = " | "
        var result: [(String, [MarkSpan])] = []
        var offset = 0
        for rawCell in line.text.components(separatedBy: separator) {
            let leading = rawCell.prefix(while: { $0.isWhitespace }).count
            let trailing = rawCell.reversed().prefix(while: { $0.isWhitespace }).count
            let length = max(0, rawCell.count - leading - trailing)
            let cellRange = NSRange(location: offset + leading, length: length)
            let cellText = String(Array(rawCell)[leading ..< leading + length])
            result.append((cellText, overlapping(line.spans, with: cellRange)))
            offset += rawCell.count + separator.count
        }
        return result
    }

    private static func linesWithSpans(_ text: String, spans: [MarkSpan]) -> [(text: String, spans: [MarkSpan])] {
        var offset = 0
        return text.components(separatedBy: "\n").map { line in
            defer { offset += line.count + 1 }
            return (line, overlapping(spans, with: NSRange(location: offset, length: line.count)))
        }
    }

    /// Removes the visible prefix "- " (bullets) or "N. " (steps), clipping a
    /// mark that fell (partly) inside it instead of discarding it.
    private static func stripListPrefix(_ line: (text: String, spans: [MarkSpan])) -> (text: String, spans: [MarkSpan]) {
        var prefixLength = 0
        if line.text.hasPrefix("- ") {
            prefixLength = 2
        } else if let match = line.text.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
            prefixLength = line.text.distance(from: line.text.startIndex, to: match.upperBound)
        }
        let stripped = String(line.text.dropFirst(prefixLength))
        let adjusted: [MarkSpan] = line.spans.compactMap { span in
            let newStart = span.range.location - prefixLength
            if newStart < 0 {
                let clippedLength = span.range.length + newStart
                guard clippedLength > 0 else { return nil }
                return MarkSpan(range: NSRange(location: 0, length: clippedLength), markId: span.markId)
            }
            return MarkSpan(range: NSRange(location: newStart, length: span.range.length), markId: span.markId)
        }
        return (stripped, adjusted)
    }

    private static func markerText(_ plain: String, spans: [MarkSpan]) -> String {
        guard !spans.isEmpty else { return plain }
        let chars = Array(plain)
        var result = ""
        var cursor = 0
        for span in spans.sorted(by: { $0.range.location < $1.range.location }) {
            let start = max(0, min(span.range.location, chars.count))
            let end = max(start, min(span.range.location + span.range.length, chars.count))
            guard end > start else { continue }
            if start > cursor { result += String(chars[cursor ..< start]) }
            result += "{{\(span.markId)|\(String(chars[start ..< end]))}}"
            cursor = end
        }
        if cursor < chars.count { result += String(chars[cursor...]) }
        return result
    }
}
