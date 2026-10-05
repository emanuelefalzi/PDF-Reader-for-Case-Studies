import Foundation

/// Raw shape of `structured_output` for an analysis call (SPEC §7.5,
/// `Resources/Schemas/analysis.schema.json`), before post-processing
/// (`AnalysisPostProcessor`). `RewriteItem` (Store, `AnalysisRecord.swift`)
/// already has the same fields as the schema (`kind/text/items/columns/rows`):
/// reused here rather than duplicated.
struct AnalysisResponseRaw: Sendable, Codable, Equatable {
    var title: String
    var rewrite: [RewriteItem]
    var marks: [AnalysisMarkRaw]
    var links: [AnalysisLinkRaw]
}

/// A mark as Claude returns it (SPEC schema `marks[]`): `id` required,
/// `termId` optional (only if it reuses a glossary concept, SPEC §7.5
/// point 11).
struct AnalysisMarkRaw: Sendable, Codable, Equatable {
    var id: String
    var text: String
    var mark: MarkType
    var term: String
    var termId: String?
}

/// A link as Claude returns it (SPEC schema `links[]`): `via` optional, the
/// id of the underline/arrow mark that expresses the relationship.
struct AnalysisLinkRaw: Sendable, Codable, Equatable {
    var from: String
    var to: String
    var via: String?
    var label: String
    var kind: LinkKind
}
