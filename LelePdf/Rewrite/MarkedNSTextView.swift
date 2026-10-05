import AppKit

/// The real `NSTextView` behind `MarkedTextView` (see there for the technical
/// choice): not editable, draws the 4 marks over the text background and
/// reports hover as `model.setHover(termId:)`.
final class MarkedNSTextView: NSTextView {
    weak var model: DocumentModel?
    var blockId: String?
    /// A triple-click starts in-place editing; `nil` disables the hit test
    /// (non-editable lines, e.g. the Summary Lab preview).
    var onTripleClick: ((Int) -> Void)?
    private var marks: [MarkedTextBuilder.MarkedRange] = []
    /// Search occurrences to highlight, in the same coordinate system as
    /// `marks`.
    private var searchHighlightRanges: [NSRange] = []
    private var trackingArea: NSTrackingArea?
    private var hoverObserver: NSObjectProtocol?
    /// SPEC §5.4 v2.6 "Color per subject": like `hoverObserver` above, needed
    /// because this AppKit view does not redraw itself by following
    /// `@Observable`. It is needed here ALSO because `BlockCardView: Equatable`
    /// can skip `body` (and therefore `MarkedTextView.updateNSView`, which
    /// would redo `configure(...)` with the right colors) when the color
    /// change is the ONLY thing that changed in a block.
    private var colorThemeObserver: NSObjectProtocol?
    /// Last observed hover identity (SPEC §5.8, fluidity): lets the view
    /// redraw only when the computed state of a mark in THIS card really
    /// changes, not on every hover change anywhere in the app. Previously
    /// every `MarkedNSTextView` in the window (one per row/cell, often dozens
    /// per page) set `needsDisplay = true` on every mouse move, even when it
    /// contained no mark for the term involved. Comparing `termId` alone had a
    /// flaw found in cross-review: moving between two marks with the SAME
    /// termId but a different `markId` did not change `termId`, so nothing
    /// was redrawn even though the exact state to show had changed. That is
    /// why `blockId` is part of the identity too.
    private var lastHoverIdentity = HoverIdentity(termId: nil, markId: nil, blockId: nil)
    /// Font and line spacing of the last `configure(...)`: `drawShape` needs
    /// them to compute a line rectangle tight around the glyph instead of the
    /// whole line (fixes circles that were too large), see
    /// `MarkGeometry.circleGlyphRect`.
    private var currentFont: NSFont = .systemFont(ofSize: 13)
    private var currentLineSpacing: CGFloat = 4

    /// Explicit designated initializer (not inherited): declaring
    /// `required init?(coder:)` below breaks the automatic inheritance of
    /// `NSTextView`'s designated initializers (Swift rule: a subclass that
    /// provides its own designated initializer inherits the parent's others
    /// only if it implements all of them), so it has to be written by hand
    /// for `convenience init()` to call it with `self.init(...)`.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        container?.lineFragmentPadding = 0
        // `object: nil`: we do not filter by model (avoids reading
        // `notification.object`, which is not `Sendable`, inside the closure).
        // Harmless: at worst one extra redraw when another window changes
        // hover, never a wrong mark (each view still reads its own
        // `model.hoveredTermId`).
        hoverObserver = NotificationCenter.default.addObserver(forName: .lelePdfHoverChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                PerfProbe.hit("text.hoverNotification")
                let new = HoverIdentity(termId: self.model?.hoveredTermId, markId: self.model?.hoveredMarkId, blockId: self.model?.hoveredMarkBlockId)
                let old = self.lastHoverIdentity
                self.lastHoverIdentity = new
                guard old != new else { return }
                // Redraw only if the computed state of AT LEAST one mark in
                // this card really changes between `old` and `new` (same pure
                // function as the real drawing, `HoverLinking.state`, not a
                // hand-written comparison on `termId` alone; see the comment
                // on `lastHoverIdentity`).
                let changed = self.marks.contains { mark in
                    let oldState = HoverLinking.state(
                        markId: mark.markId, blockId: self.blockId, termId: mark.termId, isRepetition: false,
                        hoveredMarkId: old.markId, hoveredBlockId: old.blockId, hoveredTermId: old.termId
                    )
                    let newState = HoverLinking.state(
                        markId: mark.markId, blockId: self.blockId, termId: mark.termId, isRepetition: false,
                        hoveredMarkId: new.markId, hoveredBlockId: new.blockId, hoveredTermId: new.termId
                    )
                    return oldState != newState
                }
                guard changed else { return }
                self.needsDisplay = true
            }
        }
        colorThemeObserver = NotificationCenter.default.addObserver(forName: .lelePdfColorThemeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reapplyMarkTextColors()
            }
        }
    }

    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// `NotificationCenter` retains block-observer tokens even when the closure
    /// captures `self` weakly. The SwiftUI bridge calls this method in
    /// `dismantleNSView`, avoiding the tokens and empty callbacks that would
    /// otherwise pile up every time a card is rebuilt.
    func stopObserving() {
        let center = NotificationCenter.default
        if let hoverObserver { center.removeObserver(hoverObserver) }
        if let colorThemeObserver { center.removeObserver(colorThemeObserver) }
        hoverObserver = nil
        colorThemeObserver = nil
    }

    /// Signature of the last `configure` actually applied. SwiftUI calls
    /// `updateNSView` (and therefore `configure`) every time the row's `body`
    /// is re-evaluated (a keystroke in the Search field, opening/closing the
    /// edit of another line in the same card, a context mutation), even when
    /// text, marks and font are identical to before. Previously every call
    /// rebuilt the `NSAttributedString`, emptied the measured-height cache
    /// (so TextKit re-measured everything on the next pass) and invalidated
    /// the intrinsic size (one more layout pass). The benchmark measured
    /// 14-28 reconfigurations for one added mark or one arriving analysis, all
    /// on rows whose text had not changed.
    private struct ConfigurationKey: Equatable {
        var text: String
        var marks: [MarkedTextBuilder.MarkedRange]
        var fontSize: CGFloat
        var textColor: NSColor
        var lineSpacing: CGFloat
        var italic: Bool
        var serif: Bool
    }
    private var appliedConfiguration: ConfigurationKey?
    /// Diagnostics (tests): how many times `configureBody` really ran.
    private(set) var appliedConfigurationCount = 0

    func configure(text: String, marks: [MarkedTextBuilder.MarkedRange], fontSize: CGFloat, textColor: NSColor, lineSpacing: CGFloat, italic: Bool = false, serif: Bool = false, searchHighlightRanges: [NSRange] = []) {
        let key = ConfigurationKey(text: text, marks: marks, fontSize: fontSize, textColor: textColor, lineSpacing: lineSpacing, italic: italic, serif: serif)
        if key != appliedConfiguration {
            appliedConfiguration = key
            appliedConfigurationCount += 1
            PerfProbe.measure("text.configure") {
                configureBody(text: text, marks: marks, fontSize: fontSize, textColor: textColor, lineSpacing: lineSpacing, italic: italic, serif: serif)
            }
        } else {
            PerfProbe.hit("text.configure.unchanged")
        }
        if self.searchHighlightRanges != searchHighlightRanges {
            self.searchHighlightRanges = searchHighlightRanges
            needsDisplay = true
        }
    }

    /// The single place that builds the base font of a right-hand panel line.
    /// `italic`/`serif` default to `false`, so every pre-existing caller stays
    /// identical to before.
    private static func baseFont(size: CGFloat, italic: Bool, serif: Bool) -> NSFont {
        var font: NSFont
        if serif, let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif),
           let serifFont = NSFont(descriptor: descriptor, size: size) {
            font = serifFont
        } else {
            font = .systemFont(ofSize: size)
        }
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private func configureBody(text: String, marks: [MarkedTextBuilder.MarkedRange], fontSize: CGFloat, textColor: NSColor, lineSpacing: CGFloat, italic: Bool, serif: Bool) {
        self.marks = marks
        let font = Self.baseFont(size: fontSize, italic: italic, serif: serif)
        currentFont = font
        currentLineSpacing = lineSpacing
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ])
        let hue = model?.colorTheme ?? .default
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for mark in marks where mark.range.location + mark.range.length <= (text as NSString).length {
            attributed.addAttribute(.foregroundColor, value: MarkPalette.colors(for: mark.type, hue: hue).text, range: mark.range)
            // The `circle` mark is by definition an actor, a number or a date
            // (SPEC §5.4/analysis.md point 12). On top of the color applied
            // above, make it bold so numbers and proper names stand out at a
            // glance inside a bullet or sub-point full of text, not only by
            // tint.
            if mark.type == .circle {
                attributed.addAttribute(.font, value: boldFont, range: mark.range)
            }
        }
        textStorage?.setAttributedString(attributed)
        measuredHeightByWidth.removeAll() // text/marks/font changed: the cached heights are no longer valid
        needsDisplay = true
        PerfProbe.hit("text.intrinsicInvalidate.configure")
        invalidateIntrinsicContentSize()
        lastIntrinsicHeight = nil // text/marks really changed: the next layout() must always be able to invalidate again
    }

    /// SPEC §5.4 v2.6 "Changing it immediately updates ... the rewrite":
    /// `configure(...)` colors the marks' text once, as a string attribute
    /// (not redrawn on every `draw(_:)` like the shapes below, see
    /// `drawShape`). A hue change on already-built cards must therefore update
    /// that attribute directly, without waiting for a new `configure(...)` that
    /// might never arrive (`BlockCardView: Equatable`).
    private func reapplyMarkTextColors() {
        guard let textStorage, !marks.isEmpty else { return }
        let hue = model?.colorTheme ?? .default
        let length = textStorage.length
        textStorage.beginEditing()
        for mark in marks where mark.range.location + mark.range.length <= length {
            textStorage.addAttribute(.foregroundColor, value: MarkPalette.colors(for: mark.type, hue: hue).text, range: mark.range)
        }
        textStorage.endEditing()
        needsDisplay = true
    }

    /// Height already computed for each proposed width, cleared only by
    /// `configure(...)` (text/marks/font really changed). SwiftUI queries
    /// `sizeThatFits` of EVERY `NSViewRepresentable` dozens of times per layout
    /// pass (different proposals: minimum, ideal, maximum, intermediate widths
    /// of nested stacks). The benchmark measured 28,563 calls to
    /// `measuredSize` for a single divider-drag event, 14.7 s out of 15.5 s,
    /// because every call changed `containerSize` and redid the whole TextKit
    /// layout. With the cache the same pass costs one dictionary lookup per
    /// repeated proposal. Re-wrapping at the on-screen width is still
    /// guaranteed by `syncContainerWidthIfNeeded()` in `layout()`/`draw(_:)`,
    /// which always compares against `bounds.width`, not against this cache.
    private var measuredHeightByWidth: [CGFloat: CGFloat] = [:]

    /// SwiftUI's "minimum" proposal (width 0, asked of every view in every
    /// `HStack`/`Grid`) used to wrap the whole text at one character per line,
    /// the most expensive TextKit measurement of all (up to ~5 ms for a
    /// paragraph) and useless: that height never determines the final layout
    /// (the real width comes from the container, never from 0). Instead we
    /// answer with the height of a single line (the measurement at infinite
    /// width, which is requested anyway and cached): it is the minimum height
    /// the text can have, consistent with a minimum proposal.
    static let minimumMeaningfulWidth: CGFloat = 1.5

    func measuredSize(forWidth width: CGFloat) -> CGSize {
        guard let textContainer, let layoutManager else { return CGSize(width: width, height: 0) }
        if width < Self.minimumMeaningfulWidth {
            PerfProbe.hit("text.measure.minProbe")
            return CGSize(width: width, height: measuredSize(forWidth: .greatestFiniteMagnitude).height)
        }
        let key = max(1, width)
        if let cached = measuredHeightByWidth[key] {
            PerfProbe.hit("text.measure.cached")
            return CGSize(width: width, height: cached)
        }
        return PerfProbe.measure("text.measure") {
            textContainer.containerSize = NSSize(width: key, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let height = used.height.rounded(.up)
            measuredHeightByWidth[key] = height
            return CGSize(width: width, height: height)
        }
    }

    /// Fix for a real bug (overlapping cards / text spilling outside the card,
    /// seen in a screenshot of the installed app; see
    /// `LelePdfTests/CardItemOverlapTests.swift` for the reproduction).
    /// `MarkedTextView.sizeThatFits(_:nsView:context:)` is the only way SwiftUI
    /// asks this view how much text fits at the current width. But when the
    /// right-hand panel's width changes WITHOUT the text/marks changing
    /// (`configure(...)` is not called again), for example because of
    /// `RewriteScrollHost` (`NSHostingView.sizingOptions =
    /// [.intrinsicContentSize]` inside an `NSScrollView` with a "legacy" bar
    /// that reserves space, or a resized window), SwiftUI/AppKit may place
    /// this view again with a width different from the LAST `sizeThatFits`
    /// actually served, without calling it again for the new width
    /// (reproduced empirically: `hostingView.bounds` shrinks correctly, but
    /// the text stays wrapped for the old width and spills out). This view
    /// corrects itself as soon as AppKit gives it a `bounds` whose width no
    /// longer matches the one used for the last text wrap: it re-wraps
    /// immediately for the real width and, if the required height changes,
    /// invalidates the intrinsic size so SwiftUI asks for it again
    /// (documented by Apple for `NSViewRepresentable`: "if your custom view's
    /// size changes for reasons other than being told by SwiftUI, call
    /// invalidateIntrinsicContentSize()").
    ///
    /// **No cache of the last re-wrapped width.** An earlier version of this
    /// fix kept one (`lastWrappedWidth`) to exit early if the width had not
    /// changed "since last time". It was reproduced with a real multi-width
    /// case (the "Atari" card, see
    /// `LelePdfTests/HoverVisibilityAndAtariCardTests.swift`) that at only ONE
    /// panel width out of four (470 pt, not 320/392/520) the text stayed wrapped
    /// too wide even with `bounds.width` already correct: the cache could treat
    /// as "already re-wrapped" a width never really synchronized with
    /// `textContainer`, if `layout()` was called more than once with the same
    /// `bounds.width` but `sizeThatFits` (`measuredSize(forWidth:)`, called
    /// with another value in the meantime) had set
    /// `textContainer.containerSize` to a different width. The comparison is
    /// now always against `textContainer.containerSize.width` itself (not a
    /// copy).
    ///
    /// **Always re-wrap for real** (for drawing correctness), but call
    /// `invalidateIntrinsicContentSize()` ONLY when the resulting HEIGHT really
    /// changes (0.5 pt tolerance), never unconditionally and never from
    /// `draw(_:)`. A real crash of the test process
    /// (`RewritePanelLateContextObservationTests`, an Obj-C exception from
    /// `NSHostingView`/`GraphHost.flushTransactions` during a layout turn)
    /// came from here: invalidating the intrinsic size for every pixel of
    /// width difference, EVEN when the real height did not change at all (e.g.
    /// the last line gets one character shorter/longer without adding or
    /// removing a line), and EVEN inside `draw(_:)` (which runs DURING a
    /// layout/display turn, never the right place to request another),
    /// created a loop of invalidations that AppKit breaks with an exception
    /// ("too many `setNeedsUpdateConstraints` during layout"). Re-wrapping
    /// alone (without invalidating) is still enough for drawing: `draw(_:)`
    /// calls only that, never the invalidation.
    private var lastIntrinsicHeight: CGFloat?

    @discardableResult
    private func syncContainerWidthIfNeeded() -> Bool {
        guard let textContainer, let layoutManager else { return false }
        let currentWidth = bounds.width
        guard currentWidth > 0, textContainer.containerSize.width != currentWidth else { return false }
        PerfProbe.measure("text.syncWidth") {
            textContainer.containerSize = NSSize(width: currentWidth, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
        }
        return true
    }

    override func layout() {
        super.layout()
        let currentWidth = bounds.width
        guard syncContainerWidthIfNeeded(), let textContainer, let layoutManager else { return }
        let newHeight = layoutManager.usedRect(for: textContainer).height.rounded(.up)
        // First `layout()` of a newly built view (a card that entered the lazy
        // window): if SwiftUI has already sized us with the height measured for
        // THIS width (`measuredSize`), there is nothing to invalidate. This
        // saves a layout pass of the whole panel for every new text view.
        if lastIntrinsicHeight == nil, let known = measuredHeightByWidth[currentWidth], abs(known - newHeight) < 0.5 {
            lastIntrinsicHeight = newHeight
            return
        }
        if lastIntrinsicHeight == nil || abs(newHeight - lastIntrinsicHeight!) >= 0.5 {
            lastIntrinsicHeight = newHeight
            PerfProbe.hit("text.intrinsicInvalidate.layout")
            invalidateIntrinsicContentSize()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let layoutManager, let textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let charIndex = layoutManager.characterIndex(for: containerPoint, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard charIndex != NSNotFound, let mark = marks.first(where: { NSLocationInRange(charIndex, $0.range) }) else {
            model?.setHover(termId: nil)
            return
        }
        // `blockId` is that of THIS card: every `MarkedNSTextView` draws the
        // marks of a single block, so it is always the true owner of
        // `mark.markId` (numbering is local to the block, never unique in the
        // document).
        model?.setHover(termId: mark.termId, markId: mark.markId, blockId: blockId)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        model?.setHover(termId: nil)
    }

    /// SPEC §5.8 "a click brings the other side to it": a click on a marked
    /// term scrolls the PDF to the corresponding mark, instead of starting a
    /// text selection there. Elsewhere a click selects normally
    /// (`isSelectable = true`, unchanged).
    override func mouseDown(with event: NSEvent) {
        guard let layoutManager, let textContainer else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let charIndex = layoutManager.characterIndex(for: containerPoint, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        // A triple-click starts in-place editing, with the caret where the user
        // clicked. This comes before any other click behavior (navigation to
        // a mark included: a triple-click on a marked term edits the line,
        // it does not jump to the PDF). No `super.mouseDown` here: this view
        // is about to be replaced by the editor, and selecting a paragraph
        // here would only be a useless visual flash.
        if event.clickCount == 3, let onTripleClick, charIndex != NSNotFound {
            onTripleClick(charIndex)
            return
        }
        if charIndex != NSNotFound, let mark = marks.first(where: { NSLocationInRange(charIndex, $0.range) }) {
            model?.syncCoordinator.handlePanelTermClicked(termId: mark.termId, markId: mark.markId, blockId: blockId)
            return
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Last safety net before actually drawing (see the comment on
        // `syncContainerWidthIfNeeded`/`layout()` above): `draw(_:)` always
        // receives the true, final `bounds`, so this is the right place to
        // guarantee that the drawn text and marks ALWAYS match the width seen
        // on screen, even in the rare cases where `layout()` alone was not
        // enough.
        syncContainerWidthIfNeeded()
        drawMarkBackgrounds()
        drawSearchHighlights()
        super.draw(dirtyRect)
    }

    /// Yellow background (system find style) on the real occurrences of the
    /// query in this line. Same technique as `drawMarkBackgrounds` below, as a
    /// second independent layer (a line can have both a mark and a search
    /// occurrence overlapping).
    private func drawSearchHighlights() {
        guard !searchHighlightRanges.isEmpty, let layoutManager, let textContainer,
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.45).cgColor)
        for range in searchHighlightRanges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                context.fill(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).insetBy(dx: -1, dy: -0.5))
            }
        }
        context.restoreGState()
    }

    private func drawMarkBackgrounds() {
        guard let layoutManager, let textContainer, let context = NSGraphicsContext.current?.cgContext else { return }
        PerfProbe.hit("text.draw")
        for mark in marks {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil)
            var rects: [NSRect] = []
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                rects.append(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
            }
            guard !rects.isEmpty else { continue }
            let state = HoverLinking.state(
                markId: mark.markId,
                blockId: blockId,
                termId: mark.termId,
                isRepetition: false,
                hoveredMarkId: model?.hoveredMarkId,
                hoveredBlockId: model?.hoveredMarkBlockId,
                hoveredTermId: model?.hoveredTermId
            )
            drawShape(type: mark.type, rects: rects, state: state, context: context)
        }
    }

    private func drawShape(type: MarkType, rects: [NSRect], state: MarkState, context: CGContext) {
        let colors = MarkPalette.colors(for: type, hue: model?.colorTheme ?? .default)
        let alpha = MarkGeometry.opacity(for: state)
        let strokeWidth: CGFloat = (type == .underline || type == .arrow ? MarkGeometry.underlineWidth : 1) + MarkGeometry.strokeBonus(for: state)
        // Clearer hover: the same darkening as the PDF side
        // (`MarksOverlayDrawing.swift`/`RectangleMarksOverlay.swift`); the two
        // sides must light up the same way for the same mark.
        let darken = MarkGeometry.fillDarkenFraction(for: state)
        let fillColor = colors.fill.darkened(by: darken)
        let strokeColor = colors.stroke.darkened(by: darken)
        // Height of the glyph alone (without line spacing), for the circle: see
        // `MarkGeometry.circleGlyphRect`.
        let glyphHeight = currentFont.ascender - currentFont.descender
        context.saveGState()
        defer { context.restoreGState() }
        switch type {
        case .rectangle:
            for rect in rects {
                let path = CGPath(roundedRect: MarkGeometry.rectFillRect(around: rect), cornerWidth: MarkGeometry.rectCornerRadius, cornerHeight: MarkGeometry.rectCornerRadius, transform: nil)
                context.addPath(path)
                context.setFillColor(fillColor.withAlphaComponent(alpha).cgColor)
                context.fillPath()
            }
            // Clearer hover (a 1.5-2 pt border for the rectangle): in the
            // normal/repetition state it stays a solid fill without an outline
            // (design unchanged), but when hovered/linked/selected a border,
            // in the same darkened color as the fill, makes it clearly
            // distinguishable even where the solid fill alone is not enough.
            if MarkGeometry.strokeBonus(for: state) > 0 {
                for rect in rects {
                    let path = CGPath(roundedRect: MarkGeometry.rectFillRect(around: rect), cornerWidth: MarkGeometry.rectCornerRadius, cornerHeight: MarkGeometry.rectCornerRadius, transform: nil)
                    context.addPath(path)
                    context.setStrokeColor(strokeColor.withAlphaComponent(alpha).cgColor)
                    context.setLineWidth(strokeWidth)
                    context.strokePath()
                }
            }
        case .circle:
            for rect in rects {
                let glyphRect = MarkGeometry.circleGlyphRect(lineRect: rect, glyphHeight: glyphHeight, lineSpacing: currentLineSpacing)
                let path = CGPath(ellipseIn: glyphRect, transform: nil)
                context.addPath(path)
                context.setStrokeColor(strokeColor.withAlphaComponent(alpha).cgColor)
                context.setLineWidth(strokeWidth)
                context.strokePath()
            }
        case .underline, .arrow:
            // `NSTextView` is "flipped" (y pointing down): the line sits near
            // `rect.maxY`, not `minY` as in the PDF page space (not flipped,
            // used by `MarksOverlayDrawing.swift`).
            context.setStrokeColor(strokeColor.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(strokeWidth)
            for rect in rects {
                let y = rect.maxY - 2
                context.move(to: CGPoint(x: rect.minX, y: y))
                context.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.strokePath()
            if type == .arrow, let last = rects.last {
                let y = last.maxY - 2
                let points = MarkGeometry.arrowheadPoints(from: CGPoint(x: last.minX, y: y), to: CGPoint(x: last.maxX, y: y))
                context.setFillColor(strokeColor.withAlphaComponent(alpha).cgColor)
                context.move(to: points[0])
                context.addLine(to: points[1])
                context.addLine(to: points[2])
                context.closePath()
                context.fillPath()
            }
        }
    }
}
