import AppKit
@preconcurrency import PDFKit

/// Selection mini bar with two modes: **new selection** (marks + T1-T4,
/// SPEC §5.7/v2.3 §5.3) and **existing mark** clicked (Change + Remove, SPEC
/// "Change or remove"). An extension of `MarksOverlayView`, kept separate to
/// stay within ~12 KB per file.
@MainActor
extension MarksOverlayView {
    private static let markGlyphs: [(MarkType, String)] = [
        (.rectangle, "rectangle"), (.circle, "circle"), (.underline, "underline"), (.arrow, "arrow.turn.right.down"),
    ]

    /// `.PDFViewSelectionChanged` (SPEC §5.7 "text is selected in the PDF and
    /// a mini bar appears"): hides the bar if the selection is empty,
    /// otherwise shows it in "new selection" mode.
    func handleSelectionChanged() {
        PerfProbe.measure("overlay.selectionChanged") { handleSelectionChangedBody() }
    }

    private func handleSelectionChangedBody() {
        // During a drag (button pressed) no rebuild: the bar hides
        // immediately and reappears just once at mouse-up
        // (`handleSelectionBarMouseUp`), on the final selection. A selection
        // change with no button pressed (keyboard, accessibility,
        // `setCurrentSelection` from code) stays immediate.
        if isLeftMouseButtonPressed() {
            selectionBar.isHidden = true
            selectionBarAnchor = nil
            selectionBarRefreshPending = true
            clearSelectedMark()
            return
        }
        guard let pdfView, let selection = pdfView.currentSelection,
              let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = selection.pages.first else {
            selectionBar.isHidden = true
            selectionBarAnchor = nil
            clearSelectedMark()
            return
        }
        clearSelectedMark() // a new text selection is no longer a "selected" mark (SPEC §5.4).
        // Multi-selection: once ⌘ has been used to accumulate at least one
        // piece, the bar shows ONLY T1-T4 (they act on ALL the pieces in one
        // go, `DocumentModel.applyTocLevelShortcut`). The 4 marks,
        // Highlight/Underline/Strikethrough and "Analyze this section" stay
        // out of scope for a multi-selection: none of them has an obvious
        // "per piece" meaning without an explicit request, and the scope is
        // not to be widened beyond SPEC.
        if let model, !model.multiSelectionPieces.isEmpty {
            selectionBar.configure(groups: [multiSelectionTocGroup()])
        } else {
            selectionBar.configure(groups: newSelectionGroups(selection: selection) + analyzeSectionGroup(selection: selection) + [annotationTextItems(selection: selection)])
        }
        let lineRects = selection.selectionsByLine().filter { $0.pages.contains(page) }.map { $0.bounds(for: page) }
        guard !lineRects.isEmpty else { selectionBar.isHidden = true; selectionBarAnchor = nil; return }
        let pageRect = lineRects.reduce(CGRect.null) { $0.union($1) }
        selectionBarAnchor = (page, pageRect) // anchor in page space, so the bar can follow the text
        place(selectionBar, above: pdfView.convert(pageRect, from: page))
        selectionBar.isHidden = false
    }

    /// Called from the local mouse-up monitor
    /// (`MarksOverlayMultiSelection.installMultiSelectionMonitor`). Deferred
    /// to the next run loop pass: the monitor sees the event BEFORE the
    /// `PDFView` receives it, and the selection may still change in its
    /// `mouseUp`. A run loop block (`RunLoop.perform`), not
    /// `DispatchQueue.main.async`: the main queue is not drained reentrantly
    /// from inside a job already running (the case of `@MainActor` tests,
    /// where the block would never run before the test ends), while the run
    /// loop is. Not `private`: the tests call it directly.
    func handleSelectionBarMouseUp() {
        guard selectionBarRefreshPending else { return }
        selectionBarRefreshPending = false
        RunLoop.main.perform(inModes: [.default, .eventTracking]) { [weak self] in
            MainActor.assumeIsolated { self?.handleSelectionChanged() }
        }
    }

    /// The bar follows the text on every scroll/zoom: a single
    /// `PDFView.convert` per event, and only while the bar is visible.
    func repositionSelectionBar() {
        guard !selectionBar.isHidden, let anchor = selectionBarAnchor, let pdfView else { return }
        place(selectionBar, above: pdfView.convert(anchor.pageRect, from: anchor.page))
    }

    /// T1-T4 on the accumulated multi-selection: each piece becomes one
    /// entry, all at the same level, as a SINGLE change that one ⌘Z undoes
    /// (`ManualTocShortcut.apply` inside `DocumentModel.applyTocLevelShortcut`,
    /// which gives precedence to `multiSelectionPieces` when it is not
    /// empty).
    private func multiSelectionTocGroup() -> [SelectionMiniBar.Item] {
        (1 ... 4).map { level in
            SelectionMiniBar.Item(symbolName: nil, title: "T\(level)", tint: nil) { [weak self] in
                self?.model?.applyTocLevelShortcut(level: level)
                self?.selectionBar.isHidden = true
            }
        }
    }

    private func newSelectionGroups(selection: PDFSelection) -> [[SelectionMiniBar.Item]] {
        let hue = model?.colorTheme ?? .default
        let markItems = Self.markGlyphs.map { type, symbol in
            SelectionMiniBar.Item(symbolName: symbol, title: nil, tint: MarkPalette.colors(for: type, hue: hue).stroke) { [weak self] in
                self?.addManualMark(selection: selection, type: type)
            }
        }
        let tocItems = (1 ... 4).map { level in
            SelectionMiniBar.Item(symbolName: nil, title: "T\(level)", tint: nil) { [weak self] in
                self?.model?.addManualTocEntry(selection: selection, level: level)
                self?.selectionBar.isHidden = true
            }
        }
        return [markItems, tocItems]
    }

    /// The "analyze this section" action, offered in the SAME bar as the 4
    /// marks and T1-T4. It replaces a floating pill that used to appear in
    /// mid-air above a not-yet-analyzed paragraph (the user asked for the
    /// action to show up when selecting a line of text, next to the marks
    /// and T1, T2 etc.). The action is unchanged (it analyzes the block of
    /// the selection, i.e. the whole section; blocks and sections coincide).
    /// A single group (0 or 1 element): it does not appear at all if the
    /// selection does not fall in a valid block or if that block is already
    /// analyzed or in progress, the same condition as the old pill
    /// (`.idle`/`.failed`), so as not to offer an action that would silently
    /// overwrite a summary already made.
    private func analyzeSectionGroup(selection: PDFSelection) -> [[SelectionMiniBar.Item]] {
        guard let model, let document = pdfView?.document, let blocks = model.structure?.blocks,
              let resolution = ManualSelectionResolver.resolve(selection: selection, document: document, blocks: blocks) else { return [] }
        switch model.analysisController.blockState(resolution.blockId) {
        case .idle, .failed: break
        default: return []
        }
        let blockId = resolution.blockId
        let item = SelectionMiniBar.Item(symbolName: nil, title: RewriteViewModel.analyzeSectionButtonText, tint: nil) { [weak self] in
            self?.selectionBar.isHidden = true
            self?.model?.analysisController.analyze(blockId: blockId)
        }
        return [[item]]
    }

    /// SPEC §5.13 "Text tools also appear in the M7 selection mini bar,
    /// after the 4 marks and T1–T4 (visually separated)": Highlight (with
    /// the last remembered color), Underline, Strikethrough, the same
    /// annotations you would get by dragging with the Annotate bar open
    /// (`AnnotationTextMarkupCreator`, shared).
    private func annotationTextItems(selection: PDFSelection) -> [SelectionMiniBar.Item] {
        let kinds: [(AnnotationKind, String)] = [(.highlight, "highlighter"), (.underline, "underline"), (.strikeout, "strikethrough")]
        let tools: [AnnotationKind: AnnotationTool] = [.highlight: .highlight, .underline: .underline, .strikeout: .strikeout]
        return kinds.map { kind, symbol in
            SelectionMiniBar.Item(symbolName: symbol, title: nil, tint: nil) { [weak self] in
                guard let self, let model = self.model, let document = self.pdfView?.document, let tool = tools[kind] else { return }
                let paletteColor = AnnotationToolMemory.lastColor(for: tool)
                let alpha = kind == .highlight ? AnnotationPaletteColor.highlightAlpha : 1
                AnnotationTextMarkupCreator.apply(
                    kind: kind, selection: selection, document: document, controller: model.annotationController,
                    color: paletteColor.color(alpha: alpha)
                )
                self.selectionBar.isHidden = true
            }
        }
    }

    private func addManualMark(selection: PDFSelection, type: MarkType) {
        selectionBar.isHidden = true
        guard let model, let document = pdfView?.document, let blocks = model.structure?.blocks,
              let resolution = ManualSelectionResolver.resolve(selection: selection, document: document, blocks: blocks) else { return }
        Task { @MainActor [weak self] in
            await model.analysisController.addManualMark(
                blockId: resolution.blockId, type: type, text: resolution.text, page: resolution.page, cleanRange: resolution.cleanRange
            )
            self?.invalidate()
        }
    }

    // MARK: - Existing mark (SPEC "Change or remove")

    /// Called by `mouseDown` (`MarksOverlayView.swift`) when the click lands
    /// on an already existing mark. A repetition (`markId == nil`) is not a
    /// mark in its own right: no bar.
    func showMarkActionsBar(for item: PageMarkItem, at point: CGPoint) {
        guard let model, let markId = item.markId, let blockId = item.blockId else {
            selectionBar.isHidden = true
            clearSelectedMark()
            return
        }
        let hue = model.colorTheme
        let changeItems = Self.markGlyphs.map { type, symbol in
            SelectionMiniBar.Item(symbolName: symbol, title: nil, tint: MarkPalette.colors(for: type, hue: hue).stroke) { [weak self] in
                self?.selectionBar.isHidden = true
                self?.clearSelectedMark()
                Task { @MainActor in
                    await model.analysisController.changeMarkType(blockId: blockId, markId: markId, newType: type)
                    self?.invalidate()
                }
            }
        }
        let removeItem = SelectionMiniBar.Item(symbolName: "trash", title: nil, tint: .systemRed) { [weak self] in
            self?.selectionBar.isHidden = true
            self?.clearSelectedMark()
            Task { @MainActor in
                await model.analysisController.removeMark(blockId: blockId, markId: markId)
                self?.invalidate()
            }
        }
        selectionBar.configure(groups: [changeItems, [removeItem]])
        let anchorRect = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
        // Anchor in page space for the clicked mark too.
        if let page = pdfView?.document?.page(at: item.pageIndex), let pdfView {
            selectionBarAnchor = (page, pdfView.convert(anchorRect, to: page))
        } else {
            selectionBarAnchor = nil
        }
        place(selectionBar, above: anchorRect)
        selectionBar.isHidden = false
        // SPEC §5.4 "Selected": stays highlighted as long as the bar is open.
        selectedMarkId = markId
        selectedMarkBlockId = blockId
        invalidate()
    }

    private func clearSelectedMark() {
        guard selectedMarkId != nil else { return }
        selectedMarkId = nil
        selectedMarkBlockId = nil
        invalidate()
    }

    // MARK: - Positioning

    private func place(_ bar: SelectionMiniBar, above rect: CGRect) {
        var origin = CGPoint(x: rect.midX - bar.frame.width / 2, y: rect.maxY + 6)
        origin.x = max(4, min(origin.x, bounds.width - bar.frame.width - 4))
        if origin.y + bar.frame.height > bounds.height { origin.y = rect.minY - bar.frame.height - 6 }
        bar.setFrameOrigin(origin)
    }
}
