import Foundation

/// A row of the right-hand panel, derived from `AnalysisController.DocumentSegment`
/// (SPEC §5.6 "in document order"). A distinct type (instead of reusing
/// `DocumentSegment` directly) so that `ForEach`/`LazyVStack` get a stable
/// `id` while it remains a pure type, testable without `AnalysisController`
/// (the "segments -> rows" mapping).
enum RewriteRow: Identifiable, Equatable {
    case heading(id: String, title: String, level: Int, page: Int)
    case block(id: String, blockId: String)
    case exhibit(id: String, label: String, page: Int)
    /// Saved analysis not reattached to a block of the current segmentation
    /// (SPEC §7.3, `DocumentModel.orphanBlocks`): shown at its old page with
    /// the "orphan" label.
    case orphan(id: String, blockId: String, page: Int)

    var id: String {
        switch self {
        case .heading(let id, _, _, _): id
        case .block(let id, _): id
        case .exhibit(let id, _, _): id
        case .orphan(let id, _, _): id
        }
    }
}

enum RewriteViewModel {
    /// SPEC §5.6 "minimum height of 44 pt" for the placeholders of
    /// unanalyzed blocks.
    static let placeholderMinHeight: CGFloat = 44
    /// Replaces the floating "Analyze from here" pill: same action (analyze
    /// the block/section of the selection), now in the selection bar together
    /// with the 4 marks and T1-T4 (`MarksOverlaySelectionBar.swift`).
    static let analyzeSectionButtonText = String(localized: "Analyze this section")
    static let analyzeNextButtonText = String(localized: "Analyze the next block")

    /// `DocumentSegment` -> `RewriteRow`, with a stable `id` per row. Headings
    /// and Exhibits have no id of their own in the model, so theirs is built
    /// from index + page: two identical headings on different pages stay
    /// distinct, while the same heading repeated on the same page is a
    /// degenerate case that does not occur in practice.
    static func rows(from segments: [AnalysisController.DocumentSegment]) -> [RewriteRow] {
        segments.enumerated().map { offset, segment in
            switch segment {
            case .heading(let title, let level, let page):
                return .heading(id: "h-\(offset)-\(page)", title: title, level: level, page: page)
            case .block(let blockId):
                return .block(id: "b-\(blockId)", blockId: blockId)
            case .exhibit(let label, let page):
                return .exhibit(id: "e-\(offset)-\(label)-\(page)", label: label, page: page)
            }
        }
    }

    /// Rows in document order followed by the orphan analyses (SPEC §7.3,
    /// rare in practice), each with its own page and "orphan" label. They
    /// are not re-interleaved by page with the rest, to avoid carrying
    /// `context.blocks` all the way here just for this edge case.
    static func mergedRows(segments: [AnalysisController.DocumentSegment], orphans: [OrphanBlock]) -> [RewriteRow] {
        rows(from: segments) + orphans.map { .orphan(id: "o-\($0.blockId)", blockId: $0.blockId, page: $0.page) }
    }

    /// SPEC §5.5 "the block is queued (at most 5, in order)".
    static func queuedLabel(position: Int) -> String {
        String(localized: "Queued (\(position))")
    }

    /// "Claude is analyzing 3.2" plus a countdown from the ETA (SPEC §5.5):
    /// a `remainingSeconds` already negative or zero past the estimate does
    /// not show a negative number; it stays at "about 1 s".
    static func runningLabel(humanBlockLabel: String) -> String {
        String(localized: "Claude is analyzing \(humanBlockLabel)")
    }

    static func etaLabel(remainingSeconds: Double) -> String {
        let seconds = max(0, Int(remainingSeconds.rounded()))
        if seconds < 60 { return String(localized: "about \(max(seconds, 1)) s") }
        let minutes = seconds / 60
        return String(localized: "about \(minutes) min")
    }

    static func placeholderLabel(page: Int) -> String {
        String(localized: "Not analyzed yet \u{b7} p. \(page + 1)")
    }

    /// "p. 4" or "p. 4-5": the real range instead of only the starting page
    /// when a block spans several pages (SPEC §7.2), which helps tell which
    /// card belongs to which section. `start`/`end` are 0-based indices, like
    /// the rest of the module.
    static func pageRangeLabel(start: Int, end: Int) -> String {
        end > start ? "p. \(start + 1)-\(end + 1)" : "p. \(start + 1)"
    }

    static func exhibitLabel(label: String, page: Int) -> String {
        "\(label) · p. \(page + 1) ↗"
    }

    // MARK: - Protection of manual edits (SPEC §5.6)

    /// True if regenerating/re-analyzing this card needs confirmation first
    /// (SPEC "cards edited by hand ... are never overwritten without
    /// confirmation"). Today it coincides with `edited`, but it stays a
    /// function of its own: testable from the view model alone, without
    /// showing a real `NSAlert` in tests ("UI alert tested via view model"),
    /// and ready in case other conditions are needed later.
    static func needsOverwriteConfirmation(edited: Bool) -> Bool { edited }

    static let overwriteConfirmationTitle = String(localized: "This card has been edited by hand.")
    static let overwriteConfirmationMessage = String(localized: "Replace it with a new version from Claude?")

    // MARK: - Cause→effect arrow in bullet lists (SPEC §5.6, a real bug fix)

    /// Prefixes recognized at the start of a "cause→effect" line (SPEC §5.6
    /// "the → arrow indicates cause and effect"): the prompt
    /// (`Resources/Prompts/analysis.md`, fixed together with this bug) always
    /// writes "→ ", but analyses already saved to disk may have "→" without
    /// the space or an ASCII "->". All these forms must be recognized the
    /// same way, not just the new one.
    private static let arrowMarkerPrefixes = ["→ ", "→", "-> ", "->"]

    /// Non-nil if the text starts with one of the prefixes above, giving how
    /// many characters to strip to clean it (used both to choose the bullet
    /// icon and to avoid drawing the arrow twice, once as an icon and once as
    /// a literal character in the text).
    static func leadingArrowMarkerLength(in text: String) -> Int? {
        arrowMarkerPrefixes.first { text.hasPrefix($0) }?.count
    }

    /// Strips the arrow prefix (if present) from the segments of a list line,
    /// without touching any marks (`.marked`) that begin after it; the arrow
    /// itself is never part of a mark.
    static func strippingLeadingArrowMarker(_ segments: [AnalysisController.ResolvedSegment]) -> (isArrow: Bool, segments: [AnalysisController.ResolvedSegment]) {
        let plain = MarkedTextBuilder.build(segments).text
        guard let markerLength = leadingArrowMarkerLength(in: plain) else { return (false, segments) }
        var remaining = markerLength
        var result: [AnalysisController.ResolvedSegment] = []
        for segment in segments {
            guard remaining > 0 else { result.append(segment); continue }
            let text = segmentText(segment)
            if text.count <= remaining {
                remaining -= text.count // whole segment consumed by the prefix, discarded
            } else {
                result.append(segmentReplacingText(segment, with: String(text.dropFirst(remaining))))
                remaining = 0
            }
        }
        return (true, result)
    }

    private static func segmentText(_ segment: AnalysisController.ResolvedSegment) -> String {
        switch segment {
        case .plain(let text): text
        case .marked(let text, _, _, _): text
        }
    }

    private static func segmentReplacingText(_ segment: AnalysisController.ResolvedSegment, with newText: String) -> AnalysisController.ResolvedSegment {
        switch segment {
        case .plain: .plain(newText)
        case .marked(_, let markId, let termId, let type): .marked(text: newText, markId: markId, termId: termId, type: type)
        }
    }
}
