import Foundation

/// `analisi.json` (SPEC §8, `version: 1`): the marks, rewrites and links of
/// every block, plus the term registry. Separate from `documento.json`
/// because it changes far more often (every analysis) and has a `.bak` copy
/// of the previous version (SPEC §8 "Writes").
struct AnalysisRecord: Codable, Sendable, Equatable {
    var version: Int = 1
    var blocks: [String: BlockAnalysis] = [:]
    var terms: [String: TermRecord] = [:]

    /// A file with only version metadata is empty. The Store uses the
    /// distinction so as not to mistakenly replace real analyses with the
    /// initial state of another window/process.
    var hasPersistedContent: Bool { !blocks.isEmpty || !terms.isEmpty }
}

/// State of a block. Forward compatible (SPEC M3 item 1): an unknown value
/// read from a newer `analisi.json` stays readable as `.other(raw)` instead
/// of making the whole decode fail.
enum BlockAnalysisStatus: Sendable, Equatable {
    case analyzed
    case orphan
    case failed
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "analyzed": self = .analyzed
        case "orphan": self = .orphan
        case "failed": self = .failed
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .analyzed: "analyzed"
        case .orphan: "orphan"
        case .failed: "failed"
        case let .other(raw): raw
        }
    }
}

extension BlockAnalysisStatus: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Saved analysis of a block (SPEC §8 and §7.5).
struct BlockAnalysis: Codable, Sendable, Equatable {
    var status: BlockAnalysisStatus
    var analyzedAt: Date?
    var model: String?
    var title: String?
    var rewrite: [RewriteItem] = []
    /// SPEC §5.6 "Protecting edits": true if the card was edited by hand; in
    /// that case it must never be overwritten without confirmation, and
    /// "Restore Claude's version" stays available through `claudeRewrite`.
    var rewriteEdited: Bool = false
    var claudeRewrite: [RewriteItem] = []
    var marks: [Mark] = []
    var links: [Link] = []
    /// Snapshot of the marks/links PRODUCED BY CLAUDE at save time (first
    /// analysis or targeted regeneration, never touched by a later manual
    /// action): it lets "Restore Claude's version" (SPEC §5.6) give back
    /// EXACTLY what Claude had produced, even if a mark was hidden or
    /// changed type during "Edit text" (§5.6) or with a direct click on
    /// "Change"/"Remove" (§5.7). Optional with default `nil` (not `[]`): an
    /// `analisi.json` written before this addition has no such key, and an
    /// empty array would have been indistinguishable from "Claude produced no
    /// marks" for a block analyzed before this fix; `nil` instead says
    /// "snapshot not available", and `restoreClaudeVersion` leaves the marks
    /// unchanged in that case only (the earlier behavior, until the block is
    /// reanalyzed/regenerated at least once with this version of the app).
    var claudeMarks: [Mark]? = nil
    var claudeLinks: [Link]? = nil
}

/// Kind of rewrite element (SPEC §7.5 schema `analysis.schema.json`).
///
/// `outline`: from this change on it is the ONLY `kind` that Claude produces
/// for a new analysis (the `analysis.schema.json` schema is restricted to
/// this single value): a single rewrite (`rewrite`) row with `lines`, the
/// user's entire sequence of line types
/// (point/sub-point/explanation/note/formula/consequence/subheading,
/// `RewriteLineType`). The other cases remain only to DECODE an analysis
/// saved before this change: never produced again, but an old `analisi.json`
/// (kind=bullets/summary/...) stays readable without migration.
enum RewriteKind: String, Codable, Sendable {
    case summary, definition, bullets, steps, table, callout, paragraph
    case outline
}

/// Rewrite line type in the user's Word style (SPEC `analysis.schema.json`,
/// mapped onto the styleIds of the Word template: `Puntoelenco`/
/// `Sub-puntoelenco`/`Spiegazionebullet`/`Nota`/`Formula`/`Conseguenza`/
/// `GrassoTitoli`, plus `Definizione`/`Example`).
/// Forward compatible (the same principle as `BlockAnalysisStatus`): an
/// unknown value read from a future schema stays readable as `.other(raw)`
/// instead of making the decode of the whole block fail.
enum RewriteLineType: Sendable, Hashable {
    /// Bullet point: a main point, one per paragraph of the source block
    /// (the original bullet convention, kept in the Word-style format).
    case point
    /// Sub-bullet: a detail nested under the last point or consequence
    /// (maximum depth 2, as in the original bullet convention).
    case subpoint
    /// Explanation bullet: the line of prose that explains a point, right
    /// below it, at most one per point.
    case explanation
    /// Note: an annotation set apart from the main thread.
    case note
    /// Formula: a formula or fixed expression that the block presents as
    /// such.
    case formula
    /// Consequence: replaces the old "→ " convention at the start of a point
    /// (original bullet convention), the same level as `point`, an effect/result.
    case consequence
    /// Subheading (styleId `GrassoTitoli`, "Grasso Titoli"; formerly
    /// `grassotitoli`): a rare subheading that divides a section with real
    /// sub-parts not marked as headings. It NEVER enters the contents
    /// hierarchy (T1-T4); it stays a rewrite line type.
    case subheading
    /// Definition (styleId `Definizione`): a separate line, ONLY when the
    /// block's text really defines a term. Main level, like `note`.
    case definition
    /// Example (styleId `Example`): a separate line for a concrete example
    /// that the block's text really carries. Main level.
    case example
    case other(String)

    /// The types Claude can produce today (all except `.other`): for whoever
    /// needs to check that every type is handled, for example
    /// `RealWordTemplateCheck`.
    static let knownCases: [RewriteLineType] = [.point, .subpoint, .explanation, .note, .formula, .consequence, .subheading, .definition, .example]

    init(rawValue: String) {
        switch rawValue {
        case "point": self = .point
        case "subpoint": self = .subpoint
        case "explanation": self = .explanation
        case "note": self = .note
        case "formula": self = .formula
        case "consequence": self = .consequence
        case "subheading": self = .subheading
        case "definition": self = .definition
        case "example": self = .example
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .point: "point"
        case .subpoint: "subpoint"
        case .explanation: "explanation"
        case .note: "note"
        case .formula: "formula"
        case .consequence: "consequence"
        case .subheading: "subheading"
        case .definition: "definition"
        case .example: "example"
        case let .other(raw): raw
        }
    }

    /// `true` for a type that nests under the preceding point/consequence
    /// instead of sitting at the main level ("maximum depth 2":
    /// point/consequence/note/formula/subheading are at level 0,
    /// sub-point/explanation at level 1).
    var isNested: Bool {
        switch self {
        case .subpoint, .explanation: true
        default: false
        }
    }
}

extension RewriteLineType: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A rewrite line in the user's Word style: `text` may contain
/// `{{mX|shown words}}` markers like every other `RewriteItem` field
/// (SPEC §7.5).
struct RewriteLine: Codable, Sendable, Equatable {
    var type: RewriteLineType
    var text: String
}

/// An element of the rewrite (SPEC §5.6, §8). Fields not relevant to the
/// `kind` stay `nil`. `text`/`items` may contain `{{mX|shown words}}`
/// markers (SPEC §7.5).
///
/// `subItems` [requested by the user: "outline in points and sub-points"]:
/// only for `kind == .bullets`, `subItems[i]` are the sub-points of the point
/// `items[i]` (zero or more), maximum depth 2 overall (a sub-point has no
/// sub-points of its own). `nil`/absent for a point without details or for
/// `analisi.json` files written before this field existed: **backward
/// compatible by construction**: the default value `nil` makes the
/// synthesized `Codable` decode a missing key as `nil` instead of failing,
/// so already saved analyses (a flat list of `items`, without `subItems`)
/// stay readable without migration.
///
/// `lines`: only for `kind == .outline`, the user's entire sequence of line
/// types: the same backward-compatibility principle as `subItems`, an EXTRA
/// field with default `nil`, never a change of shape of an existing field.
struct RewriteItem: Codable, Sendable, Equatable {
    var kind: RewriteKind
    var text: String?
    var items: [String]?
    var subItems: [[String]]? = nil
    var columns: [String]?
    var rows: [[String]]?
    var lines: [RewriteLine]? = nil
}

/// Backward-compatible reading of a rewrite (a leading "→ " arrow reads as a
/// consequence, so analyses already saved stay valid).
/// `RewriteOutlineReader.lines(for:)` is the ONE place that turns any saved
/// `RewriteItem` (new `kind == .outline`, or an analysis saved before the
/// outline kind with `kind == .bullets`/`.summary`/...) into the same flat
/// `[RewriteLine]` shape: every reader (panel, export, quality checks,
/// edit-as-text, Markdown) goes through this instead of re-deciding on its
/// own how an old `bullets` item maps onto the new line types.
enum RewriteOutlineReader {
    /// Every line of a whole rewrite (`BlockAnalysis.rewrite`), in order,
    /// old items included: a `kind` this function does not recognise as
    /// either `.outline` or `.bullets` (summary/definition/steps/table/
    /// callout/paragraph, all from before the outline kind) is dropped here;
    /// those kinds keep their OWN rendering paths (`RewriteItemView`, `RewriteExportModel`,
    /// `MarkdownExporter`) unchanged, this reader only unifies the two
    /// bullet-shaped kinds into one line sequence.
    static func lines(for rewrite: [RewriteItem]) -> [RewriteLine] {
        rewrite.flatMap { lines(for: $0) }
    }

    static func lines(for item: RewriteItem) -> [RewriteLine] {
        switch item.kind {
        case .outline:
            return item.lines ?? []
        case .bullets:
            return legacyBulletLines(item)
        default:
            return []
        }
    }

    /// A `kind == .bullets` saved before the outline kind: `items[i]` becomes
    /// a `point` (or a `consequence` if it starts with "→ "/"-> ", the old
    /// convention, removed from the displayed text), and its `subItems[i]`
    /// become `subpoint`s right after it.
    private static func legacyBulletLines(_ item: RewriteItem) -> [RewriteLine] {
        let items = item.items ?? []
        let subItems = item.subItems ?? []
        var result: [RewriteLine] = []
        for (index, text) in items.enumerated() {
            let (isConsequence, cleaned) = strippingLegacyArrow(text)
            result.append(RewriteLine(type: isConsequence ? .consequence : .point, text: cleaned))
            if index < subItems.count {
                for sub in subItems[index] {
                    let (subIsConsequence, subCleaned) = strippingLegacyArrow(sub)
                    result.append(RewriteLine(type: subIsConsequence ? .consequence : .subpoint, text: subCleaned))
                }
            }
        }
        return result
    }

    /// The same convention already recognized by
    /// `RewriteViewModel.strippingLeadingArrowMarker`: "→ " or "-> " at the
    /// start of the text.
    private static func strippingLegacyArrow(_ text: String) -> (isConsequence: Bool, text: String) {
        if text.hasPrefix("→ ") { return (true, String(text.dropFirst(2))) }
        if text.hasPrefix("-> ") { return (true, String(text.dropFirst(3))) }
        return (false, text)
    }
}

/// Mark type (SPEC §5.4).
enum MarkType: String, Codable, Sendable {
    case rectangle, circle, underline, arrow
}

/// Where a mark or a link comes from (SPEC §5.7): Claude's, or added/changed
/// by hand.
enum MarkSource: String, Codable, Sendable {
    case claude, manual
}

/// Range of characters **in the block's clean text** (not on the page):
/// documented here because it is the only thing the Store saves. M5 converts
/// it into page ranges through `TextBlock.resolve(cleanRange:)` when it draws
/// the overlay; `page` (the mark's first page) is saved separately so it can
/// be shown without redoing that conversion.
struct MarkRange: Codable, Sendable, Equatable {
    /// Offset of the first character, in `Character`s of `TextBlock.cleanText`.
    var start: Int
    /// Length in `Character`s, the same unit as `start`.
    var length: Int
}

/// A saved mark (SPEC §8, §5.4, §5.7).
struct Mark: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var termId: String
    var type: MarkType
    /// Exact text copied from the block (SPEC §7.5 "text: copied exactly").
    var text: String
    var source: MarkSource
    /// First page of the mark (a mark straddling two pages generates more
    /// than one, SPEC §7.3 last point).
    var page: Int
    var range: MarkRange
    /// SPEC §5.7 "Claude's removed marks: they are hidden, not deleted".
    var hidden: Bool = false
}

/// Link type in the map (SPEC §5.4 table, §7.5).
enum LinkKind: String, Codable, Sendable {
    case action, effect
}

/// A link between two marks/terms (SPEC §8, §7.5).
struct Link: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var from: String
    var to: String
    var label: String
    var kind: LinkKind
    var source: MarkSource
    /// `termId` of the underline/arrow mark that expresses the relationship
    /// (SPEC §7.5 item 13, schema `links[].via`), if Claude indicated one and
    /// the mark was matched. Absent from the `documento.json` list in SPEC §8
    /// (which shows only `{id,from,to,label,kind,source}`) but needed for M8
    /// (map, SPEC §7.7 "links ... from the `links`"): added as optional with
    /// default `nil`, hence compatible with an `analisi.json` written before
    /// this addition (M5a).
    var via: String? = nil
}

/// Term registry entry (SPEC §8, §7.5 "Term registry").
struct TermRecord: Codable, Sendable, Equatable {
    var term: String
    var type: MarkType
    var firstBlockId: String
}
