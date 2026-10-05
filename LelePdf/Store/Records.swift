import Foundation

/// `documento.json` (SPEC §8, `version: 1`): everything needed to find and
/// show a document again without reanalyzing anything. It holds no
/// marks/rewrites (those are in `AnalysisRecord`) nor data the pipeline can
/// recompute (`lineRectsByPage` of `TextBlock`, etc.).
struct DocumentRecord: Codable, Sendable, Equatable {
    var version: Int = 1
    var fingerprint: String
    var fileName: String
    var lastKnownPath: String
    var pageCount: Int
    var title: String
    var toc: TocRecord
    var segmentationVersion: Int
    var blocks: [BlockRecord]
    var exhibits: [ExhibitRecord]
    var progress: ProgressRecord
    var updatedAt: Date
    /// Subject color (SPEC §5.4 v2.6, §8): chosen from the sidebar legend for
    /// THIS document. New records also save the default chosen in Settings;
    /// `nil` remains only for backward-compatible decoding of `documento.json`
    /// files written before v2.6.
    var colorTheme: MaterialHue? = nil
    /// Ids of the collapsed contents entries (hidden children). The state is
    /// remembered per document, in `documento.json`. `nil`/absent for
    /// `documento.json` files written before the collapsible contents
    /// existed: the same backward-compatible treatment as `colorTheme`
    /// above, equivalent to "no collapsed entry" (a fully expanded contents,
    /// the earlier behavior).
    var collapsedTocEntryIds: [String]? = nil

    /// Summary granularity chosen for THIS document: from a contents heading
    /// (T1-T4) of the chosen level to the next (or per paragraph). `nil` for a
    /// `documento.json` written before this setting existed, or for an
    /// existing document on which the user has not yet chosen: the current
    /// behavior stays (`BlockSegmenter.segment(paragraphs:)`, by internal
    /// section, independent of the contents), backward compatible by
    /// construction, the same principle as `colorTheme`/`collapsedTocEntryIds`
    /// above. A NEW document immediately receives the Settings default
    /// (`DocumentStore.registerDocument`).
    var summaryGranularity: SummaryGranularity? = nil

    /// A record without structure/progress is the initial one from
    /// `DocumentRecord.blank`, before the pipeline runs or any block has been
    /// analyzed. Used by the Store so that, in a merge between concurrent
    /// windows/processes, an initial/stale state does not mistakenly win over
    /// a real structure or progress already saved.
    var hasPersistedContent: Bool { !blocks.isEmpty || !toc.entries.isEmpty || !progress.analyzedBlockIds.isEmpty }

    /// Empty record for a document just seen, before the pipeline produces
    /// structure (SPEC §5.2: the first page appears immediately, the structure
    /// arrives later).
    static func blank(fingerprint: String, fileName: String, lastKnownPath: String, pageCount: Int, title: String) -> DocumentRecord {
        DocumentRecord(
            fingerprint: fingerprint,
            fileName: fileName,
            lastKnownPath: lastKnownPath,
            pageCount: pageCount,
            title: title,
            toc: TocRecord(source: .native, entries: []),
            segmentationVersion: 0,
            blocks: [],
            exhibits: [],
            progress: ProgressRecord(),
            updatedAt: Date()
        )
    }
}

/// `toc {source, entries[]}` (SPEC §8).
struct TocRecord: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable {
        case native, generated
    }

    var source: Source
    var entries: [TocEntryRecord]
}

/// Where a contents entry comes from (SPEC §8 `origin?: auto|manual`,
/// v2.3 §5.3): absent or `auto` for native/generated entries, `manual` for
/// those added or changed by hand by the user.
enum TocEntryOrigin: String, Codable, Sendable {
    case auto, manual
}

/// A saved contents entry (SPEC §8: `{id,title,level,page,origin?,pageY?}`).
/// `pageY` is the selection's vertical position in PDF page space
/// (SPEC §8): higher = closer to the start of the page, used to order
/// several headings on the same page (§5.3 "in order of position").
/// `removed` [M7-2, not in the literal SPEC §8 schema, which leaves room for
/// a "tombstone or removed flag"] records a manual removal instead of
/// making the entry vanish from the record, so "Regenerate contents" does not
/// make it reappear. It also applies to an entry created manually: it stays
/// invisible but keeps deduplicating a future automatic result.
struct TocEntryRecord: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var level: Int
    var page: Int
    var origin: TocEntryOrigin?
    var pageY: Double?
    var removed: Bool?

    init(id: String, title: String, level: Int, page: Int, origin: TocEntryOrigin? = nil, pageY: Double? = nil, removed: Bool? = nil) {
        self.id = id
        self.title = title
        self.level = level
        self.page = page
        self.origin = origin
        self.pageY = pageY
        self.removed = removed
    }
}

/// A saved block (SPEC §8: `{id, sectionPath, pageStart, pageEnd,
/// textHash, words}`). `pageStart`/`pageEnd` are 0-based, like `TextBlock`.
struct BlockRecord: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var sectionPath: [String]
    var pageStart: Int
    var pageEnd: Int
    var textHash: String
    var words: Int
}

/// A saved reference to an Exhibit/table/figure (SPEC §8).
struct ExhibitRecord: Codable, Sendable, Equatable {
    var label: String
    var page: Int
}

/// Reading and analysis progress (SPEC §8, replaces the provisional
/// `LastPageStore` of M1).
struct ProgressRecord: Codable, Sendable, Equatable {
    var analyzedBlockIds: [String] = []
    var lastReadPage: Int = 0
    var lastAnalyzedBlockId: String?
}

/// Document title for the data folder (SPEC §8: "the PDF's title if
/// meaningful, otherwise the file name without extension"). Pure, testable
/// without PDFKit.
enum DocumentTitle {
    static func resolve(metadataTitle: String?, fileName: String) -> String {
        let withoutExtension = (fileName as NSString).deletingPathExtension
        guard let metadataTitle else { return withoutExtension }
        let trimmed = metadataTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return withoutExtension }
        let lower = trimmed.lowercased()
        if lower == "untitled" || lower.hasSuffix(".pdf") {
            return withoutExtension
        }
        return trimmed
    }
}
