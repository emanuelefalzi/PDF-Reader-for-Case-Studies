import Foundation

/// "Annotations · p. N" section at the end of each chapter (SPEC §5.13
/// "Export"): highlights, text boxes and notes; "Drawings and shapes are not
/// exported". Pure, like the rest of `MarkdownExporter`.
enum AnnotationMarkdown {
    /// One Markdown fragment for every page that has at least one exportable
    /// annotation, ready to be inserted at the end of the chapter containing
    /// that page (SPEC): `MarkdownExporter` decides WHEN (at a chapter
    /// change/at the end of the document), an approximation with the same
    /// idea as M5a's `documentOrderSegments`: there is no finer page range
    /// per chapter here than the one implicit in the order of the
    /// blocks/headings.
    static func sectionsByPage(_ record: AnnotationsRecord, headingPrefix: String) -> [Int: String] {
        let exportable = record.items.filter { item in
            switch item.kind {
            case .highlight, .underline, .strikeout, .textbox, .note: true
            default: false
            }
        }
        guard !exportable.isEmpty else { return [:] }
        var byPage: [Int: [Annotation]] = [:]
        for item in exportable { byPage[item.page, default: []].append(item) }
        var result: [Int: String] = [:]
        for (page, items) in byPage {
            let ordered = items.sorted { $0.createdAt < $1.createdAt }
            var out = "\n\(headingPrefix) Annotations · p. \(page + 1)\n\n"
            for item in ordered { out += render(item) }
            result[page] = out
        }
        return result
    }

    private static func render(_ item: Annotation) -> String {
        let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch item.kind {
        case .highlight:
            return "==\(text)== (\(colorName(item.color)))\n\n"
        case .underline:
            return "<u>\(text)</u>\n\n"
        case .strikeout:
            return "~~\(text)~~\n\n"
        case .textbox:
            return "\(text)\n\n"
        case .note:
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let quoted = lines.map { "> \($0)" }.joined(separator: "\n")
            return "> [!note] p. \(item.page + 1)\n\(quoted)\n\n"
        default:
            return ""
        }
    }

    /// Name of the closest color in the Preview palette (SPEC "with the
    /// color in parentheses"): compared by Euclidean RGB distance, not by
    /// exact equality (a color chosen from a system popover may round
    /// differently in memory).
    private static func colorName(_ color: AnnotationColor) -> String {
        let names: [AnnotationPaletteColor: String] = [.yellow: "yellow", .green: "green", .blue: "blue", .pink: "pink", .purple: "purple"]
        var best: (AnnotationPaletteColor, Double) = (.yellow, .infinity)
        for candidate in AnnotationPaletteColor.allCases {
            let (r, g, b) = candidate.rgb
            let distance = pow(r - color.red, 2) + pow(g - color.green, 2) + pow(b - color.blue, 2)
            if distance < best.1 { best = (candidate, distance) }
        }
        return names[best.0] ?? "yellow"
    }
}
