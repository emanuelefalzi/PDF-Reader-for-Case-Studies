import Foundation

/// Summary granularity: chosen ONCE per document, after the contents
/// (T1-T4, §5.3) has been fixed and before analysis starts. A block runs
/// from a contents heading of the chosen level (or a higher one, i.e. a
/// lower number) to the next one of the same level or higher; `.paragraph`
/// does not use the contents at all, each paragraph is a block of its own.
///
/// `nil` in `DocumentRecord.summaryGranularity` keeps the PREVIOUS
/// behavior (`BlockSegmenter.segment(paragraphs:)`, grouping by the
/// internal `Paragraph.sectionPath`, independent of the hand-curated
/// T1-T4 contents), so it is backward compatible by construction and no
/// existing document changes segmentation on its own. Only a NEW document
/// immediately receives the default value from Settings
/// (`DefaultSummaryGranularityPreference`), and only by explicitly picking
/// a granularity (menu, right panel, Contents tab) does it move to the new
/// contents-based path (`BlockSegmenter.segment(paragraphs:tocEntries:granularity:)`).
enum SummaryGranularity: String, Codable, Sendable, CaseIterable, Identifiable {
    case paragraph
    case heading3
    case heading2
    case chapter

    var id: String { rawValue }

    /// English label (user-facing strings are in English).
    var label: String {
        switch self {
        case .paragraph: String(localized: "Paragraph")
        case .heading3: String(localized: "Heading 3")
        case .heading2: String(localized: "Heading 2")
        case .chapter: String(localized: "Chapter (Heading 1)")
        }
    }

    /// "Summarise by: ...": the same short label used in the right panel and
    /// in the Contents tab.
    var summariseByLabel: String { String(localized: "Summarise by: \(label)") }

    /// Compact label for the segmented control of the right panel's initial
    /// state (`RewritePanelGranularityControl.swift`, checked at 320 pt like
    /// the panel's other controls): "Chapter (Heading 1)" does not fit in four
    /// segments at that width, the others do.
    var shortLabel: String {
        switch self {
        case .paragraph: String(localized: "Paragraph")
        case .heading3: String(localized: "Heading 3")
        case .heading2: String(localized: "Heading 2")
        case .chapter: String(localized: "Chapter")
        }
    }

    /// Contents level threshold (T1-T4, `TocEntry.level`): an entry with
    /// level <= this threshold opens a new block. `nil` for `.paragraph`,
    /// which does not use the contents (each paragraph is already the finest
    /// possible block).
    var tocLevelThreshold: Int? {
        switch self {
        case .paragraph: nil
        case .heading3: 3
        case .heading2: 2
        case .chapter: 1
        }
    }

    /// Per-block length caps, revised per granularity: the wider the chosen
    /// section, the higher the cap, otherwise a whole chapter would still be
    /// split into as many small parts as a T3 and defeat the user's choice.
    /// `heading3` keeps EXACTLY the earlier numbers (700/250-600, verified and
    /// unchanged behavior); `heading2`/`chapter` double/quadruple them (an
    /// explicit numeric decision, since no number was specified).
    struct Caps: Sendable, Equatable {
        var sectionMaxWords: Int
        var partMinWords: Int
        var partMaxWords: Int
    }

    var caps: Caps {
        switch self {
        case .paragraph: Caps(sectionMaxWords: 700, partMinWords: 250, partMaxWords: 600)
        case .heading3: Caps(sectionMaxWords: 700, partMinWords: 250, partMaxWords: 600)
        case .heading2: Caps(sectionMaxWords: 1400, partMinWords: 500, partMaxWords: 1100)
        case .chapter: Caps(sectionMaxWords: 2800, partMinWords: 900, partMaxWords: 2000)
        }
    }

    /// Explicit density target passed to Claude's input (SPEC §7.5) ONLY for
    /// granularities wider than a section (`heading3`, the previous behavior,
    /// stays without an explicit target: the already verified "one point per
    /// paragraph" prompt does not change for that granularity). `nil` = no
    /// line added to the input (`heading3`/`paragraph`).
    func targetOutlinePoints(forBlockWords words: Int) -> Int? {
        switch self {
        case .paragraph, .heading3:
            return nil
        case .heading2:
            return max(4, min(12, words / 120))
        case .chapter:
            return max(6, min(20, words / 200))
        }
    }
}
