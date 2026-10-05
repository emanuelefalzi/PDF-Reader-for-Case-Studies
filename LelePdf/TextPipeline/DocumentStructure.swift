import Foundation

/// Pipeline state published in `DocumentModel` (SPEC §5.2: it starts after
/// the first page is shown, never blocking the open).
enum PipelineState: Sendable, Equatable {
    case idle
    case running(progress: Double)
    case ready
    case failed(String)
}

/// Result published in `DocumentModel.structure` (SPEC §7, §8). It does not
/// include the raw `PageLayout`s: those stay in the regenerable cache
/// (`LayoutCache`) and are not needed elsewhere in the app.
struct DocumentStructure: Sendable, Equatable {
    let fingerprint: String
    let pageCount: Int
    let headings: [Heading]
    let tocCandidates: [TocCandidate]
    let exhibits: [ExhibitRef]
    let blocks: [TextBlock]
    /// PDF without selectable text (SPEC §5.2): a banner at the top center,
    /// reading stays possible anyway.
    let textlessPages: Bool
    /// Header/footer lines removed, per page (debug overlay, SPEC §11:
    /// "removed ... struck through in red").
    let removedHeaderFooterLines: [Int: [PageRect]]
    /// See `TextPipeline.Output.paragraphs`: it serves only
    /// `DocumentModel`, to recompute `blocks` at a different granularity
    /// (`BlockSegmenter.segment(paragraphs:tocEntries:granularity:)`) without
    /// redoing the extraction. Never in the `documento.json` schema.
    let paragraphs: [Paragraph]
}
