import Foundation

/// Target lookup for a click on a linked mark/term (SPEC §5.8): file kept
/// separate from `ScrollSyncCoordinator.swift` only to respect the
/// ≤ ~12 KB file size rule.
@MainActor
extension ScrollSyncCoordinator {
    /// Navigation from a surface outside the PDF (chat, concept map):
    /// brings the panel to the row aligned with the chosen page.
    /// It does not depend on `followPDF`, like the other direct clicks.
    func handlePageNavigation(pageIndex: Int) {
        guard let bridge = model?.readerBridge,
              let pageSpan = bridge.topDownPageSpan(pageIndex: pageIndex) else { return }
        handlePDFPositionNavigation(topDownY: pageSpan.top)
    }

    /// Geometric variant kept separate so the chat/map integration stays
    /// testable without having to build a real `PDFView` in the test.
    func handlePDFPositionNavigation(topDownY: CGFloat) {
        guard let lookup = AlignmentModel.segmentAt(
                  y: topDownY, side: .pdf, segments: segments
              ),
              segments.indices.contains(lookup.index) else { return }
        scrollToShow(side: .panel, topDownY: segments[lookup.index].panelStart)
    }

    /// Click on a mark in the PDF (`MarksOverlayHover`): `markId` if it is a
    /// real mark, `nil` if it is a repetition. Scrolls the panel to the
    /// card containing the mark itself (by `markId`) or, for a repetition,
    /// to the first block that marks that term (SPEC "for a repetition, the
    /// term's mark in its first block").
    func handlePDFMarkClicked(termId: String, markId: String?, blockId: String? = nil) {
        guard let rowId = blockRowId(termId: termId, markId: markId, preferredBlockId: blockId), let segment = segments.first(where: { $0.id == rowId }) else { return }
        scrollToShow(side: .panel, topDownY: segment.panelStart)
    }

    /// Click on a marked term in the rewritten text (`MarkedNSTextView`):
    /// it also keeps the `markId` of the `{{mX|...}}` marker, so the click
    /// reaches the exact mark and not a different occurrence of the same
    /// term.
    func handlePanelTermClicked(termId: String, markId: String? = nil, blockId: String? = nil) {
        guard let rowId = blockRowId(termId: termId, markId: markId, preferredBlockId: blockId), let segment = segments.first(where: { $0.id == rowId }) else { return }
        scrollToShow(side: .pdf, topDownY: segment.pdfStart)
    }

    /// Row id (`"b-<blockId>"`, same scheme as `RewriteViewModel`) of the
    /// block that owns the mark being sought, in document order.
    private func blockRowId(termId: String, markId: String?, preferredBlockId: String?) -> String? {
        guard let context = model?.analysisController.context else { return nil }
        if let preferredBlockId, let markId,
           let analysis = context.analysis.blocks[preferredBlockId],
           analysis.marks.contains(where: { $0.id == markId }) {
            return "b-\(preferredBlockId)"
        }
        if let markId {
            for block in context.blocks {
                guard let analysis = context.analysis.blocks[block.id] else { continue }
                if analysis.marks.contains(where: { $0.id == markId }) { return "b-\(block.id)" }
            }
        }
        for block in context.blocks {
            guard let analysis = context.analysis.blocks[block.id] else { continue }
            if analysis.marks.contains(where: { $0.termId == termId && !$0.hidden }) { return "b-\(block.id)" }
        }
        return nil
    }
}
