import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// Real bug seen on a screenshot of the installed app (1040 pt window, right
/// panel ~320 pt): in the card "Hirai and Sony's Response to the Wii" the
/// rewrite elements OVERLAP (one paragraph drawn on top of the previous one,
/// the mini table over the following paragraph) and the circle marks in the
/// card text spill into the lines above/below. This file reproduces the same
/// content (paragraph + table + paragraph, with a circle mark) inside a real
/// `NSWindow`/`NSHostingView` at three panel widths (320/392/520 pt),
/// measures the rectangle of EACH element with the same `PreferenceKey`
/// mechanism already used in `RewritePanel.rowFrameReader` (SPEC §5.8),
/// checks that they do not overlap and exports a PNG for visual inspection.
///
/// `CardItemsProbe` below uses the same REAL card components
/// (`CardContainer`/`RewriteItemView`, both non-`private`, also reused by the
/// Summary Lab) instead of the whole `BlockCardView`: the only difference is
/// the header (title/page chip/"…" menu), a fixed-height `HStack` unrelated
/// to the bug, which does not need measuring here.
struct ItemFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct CardItemsProbe: View {
    let items: [AnalysisController.ResolvedRewriteItem]
    let model: DocumentModel
    let blockId: String
    let onFrames: ([Int: CGRect]) -> Void

    var body: some View {
        CardContainer {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                RewriteItemView(item: item, model: model, blockId: blockId)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ItemFramesPreferenceKey.self, value: [index: geo.frame(in: .named("probe"))])
                        }
                    )
            }
        }
        .padding(14)
        .coordinateSpace(name: "probe")
        .onPreferenceChange(ItemFramesPreferenceKey.self, perform: onFrames)
    }
}

/// Exports a PNG of `view` (same mechanism as `MapRenderExportTests`).
/// NOTE: for a hierarchy with several nested `AppKitPlatformViewHost`s
/// (SwiftUI inside `NSHostingView` inside `NSScrollView` inside another
/// `NSHostingView`, as in the two resize tests below) this offscreen capture
/// may stay visually stuck on an earlier frame even when the views'
/// `frame`/`bounds` are already correct — verified empirically by printing
/// the view hierarchy right before the capture, and confirmed not to be a
/// gap in the fix itself: a direct `layer.render` produces empty/flipped
/// output for the same hierarchy (the subviews hosted by AppKit are not part
/// of the layer tree that `CALayer.render(in:)` can traverse). The numeric
/// proof for those two tests remains the assertion on the rectangles
/// (`#expect(!a.intersects(b))`) plus the direct reading of `frame`/`bounds`
/// in the hierarchy, not the PNG; the definitive visual check is the live
/// one on the real app.
@MainActor
func exportPNG(_ view: NSView, to url: URL) {
    // The capture bitmap and its PNG representation are temporary —
    // `autoreleasepool` frees them as soon as this function returns instead of
    // waiting for the next turn of the MainActor run loop (which, with several
    // exports in quick succession, as in the parameterized tests, comes after
    // all the bitmaps have already piled up).
    autoreleasepool {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

extension HeavyTestSuites {
@MainActor
@Suite("Multi-element card · no overlaps (real bug)", .serialized)
struct CardItemOverlapTests {
    private func block(_ id: String, page: Int, text: String) -> TextBlock {
        TextBlock(id: id, sectionPath: [], pageStart: page, pageEnd: page, cleanText: text, textHash: id, words: text.split(separator: " ").count, spans: [BlockPageSpan(page: page, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))], lineRectsByPage: [:])
    }

    /// Same content (in essence) as the screenshot: paragraph, mini
    /// Console/Units sold table, paragraph — with a circle mark on "Wii" in the
    /// first paragraph (SPEC §5.4).
    private func makeModelWithHiraiCard() throws -> (model: DocumentModel, items: [AnalysisController.ResolvedRewriteItem]) {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per la scheda Hirai/Sony.", fileName: "card-overlap-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "card-overlap-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))

        let paragraph1 = "Sony's PlayStation 3 launched a year after {{m1|Nintendo's Wii}} and competed directly with Microsoft's Xbox 360 despite a much higher price and a delayed line-up of exclusive titles."
        let paragraph2 = "Journalists wondered whether Afrika, one of the console's earliest announced exclusives, would ever ship, as delay followed delay through the console's difficult first two years on the market."
        let paragraph3 = "Nintendo's ability to steal a march on both rivals with a cheaper, more accessible console reshaped how the whole industry thought about motion controls and casual audiences for the rest of the decade."

        var analysis = AnalysisRecord()
        analysis.terms["t1"] = TermRecord(term: "Nintendo's Wii", type: .circle, firstBlockId: "hirai")
        analysis.blocks["hirai"] = BlockAnalysis(
            status: .analyzed, title: "Hirai and Sony's Response to the Wii",
            rewrite: [
                RewriteItem(kind: .paragraph, text: paragraph1),
                RewriteItem(kind: .paragraph, text: paragraph2),
                RewriteItem(kind: .table, columns: ["Console", "Units sold"], rows: [["Wii", "32.4 million"], ["Xbox 360", "20.9 million"], ["PS3", "15.5 million"]]),
                RewriteItem(kind: .paragraph, text: paragraph3),
            ],
            marks: [Mark(id: "m1", termId: "t1", type: .circle, text: "Nintendo's Wii", source: .claude, page: 0, range: MarkRange(start: 0, length: 14))]
        )
        let blocks = [block("hirai", page: 0, text: paragraph1 + " " + paragraph2 + " " + paragraph3)]
        model.analysisController.updateContext(
            fingerprint: "fp-card-overlap", documentTitle: "Documento di prova", blocks: blocks,
            exhibits: [], analysis: analysis, lastAnalyzedBlockId: nil, tocEntries: []
        )
        let items = try #require(model.analysisController.cardData(for: "hirai")?.rewrite)
        return (model, items)
    }

    /// Measures the real rectangles of the card's elements at a given panel
    /// width (320/392/520 pt), with two layout passes (same caution as
    /// `RewritePanelRealContentLayoutTests`/`MapRenderExportTests`:
    /// `NSHostingView.intrinsicContentSize` may need a second pass to settle at
    /// the real width).
    private func measure(panelWidth: CGFloat, pngName: String) throws -> (frames: [CGRect], totalHeight: CGFloat, hostingView: NSHostingView<AnyView>) {
        // Per-test footprint guard.
        try expectFootprintGrowthUnderGuard("CardItemOverlapTests.measure(\(Int(panelWidth))pt)") {
            let (model, items) = try makeModelWithHiraiCard()
            var collected: [Int: CGRect] = [:]
            let probe = AnyView(
                CardItemsProbe(items: items, model: model, blockId: "hirai") { collected = $0 }
                    .frame(width: panelWidth, alignment: .leading)
                    .background(Color.white)
            )
            let hostingView = NSHostingView(rootView: probe)
            hostingView.frame = CGRect(x: 0, y: 0, width: panelWidth, height: 1)
            let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
            defer { closeTestWindow(window) }
            window.isReleasedWhenClosed = false // never explicitly closed in this test.
            window.contentView = hostingView

            hostingView.layoutSubtreeIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            // A third pass after resizing to the real ideal size (`fittingSize`): the
            // real card in the panel takes its height from
            // `NSHostingView.intrinsicContentSize`/Auto Layout (`RewriteScrollHost`),
            // not from a fixed height as here — this extra pass imitates that final
            // step instead of stopping at the provisional height=1 used at opening.
            let fitting = hostingView.fittingSize
            hostingView.frame = CGRect(x: 0, y: 0, width: panelWidth, height: max(1, fitting.height))
            window.setContentSize(hostingView.frame.size)
            hostingView.layoutSubtreeIfNeeded()
            hostingView.layoutSubtreeIfNeeded()

            let outputRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            exportPNG(hostingView, to: outputRoot.appendingPathComponent(pngName))

            let frames = (0 ..< items.count).map { collected[$0] ?? .zero }
            return (frames, hostingView.bounds.height, hostingView)
        }
    }

    /// Second hypothesis ("panel resized ... height cached per item and not
    /// invalidated on width change"): the real card does not live inside an
    /// `NSHostingView` sized by a fixed SwiftUI `.frame(width:)` as above — it
    /// lives inside `RewriteScrollHost`, where the WIDTH comes from an external
    /// Auto Layout CONSTRAINT (`container.widthAnchor ==
    /// scrollView.contentView.widthAnchor`) that can change while the same
    /// `NSHostingView` stays alive (a window resize, not a new SwiftUI view).
    /// Here the same scheme is reproduced (external width constraint,
    /// `hosting.sizingOptions = [.intrinsicContentSize]`, same choice as
    /// `RewriteScrollHost`) and the constraint is CHANGED from 520 to 320 pt on
    /// the SAME view hierarchy, with a single `layoutSubtreeIfNeeded` pass after
    /// the change (not two, so as not to hide a real invalidation problem with
    /// one pass too many that a real resize notification in the app would not
    /// make).
    /// Third hypothesis, the most concrete: the real `RewriteScrollHost` (not a
    /// hand-written Auto Layout container as in the two tests above) uses
    /// `NSScrollView.hasVerticalScroller = true` without fixing a style — on a
    /// Mac with a mouse attached (not a trackpad, system setting "Show scroll
    /// bars": Always/When scrolling), AppKit picks the "legacy" style that
    /// RESERVES horizontal space for the bar (not "overlay"): the first layout
    /// pass computes the elements' height/size at the FULL width of
    /// `scrollView.contentView` (no bar yet, the content not yet knowing whether
    /// scrolling is needed), the bar appears AFTER because the content turns out
    /// taller than the visible rect, which REDUCES the width of `contentView` —
    /// but if the `sizeThatFits` measurements already taken for the individual
    /// elements are not recomputed for the new narrower width (same class of
    /// problem as the two tests above, here triggered by the bar instead of a
    /// window resize), the elements stay internally shaped for the WRONG (wider)
    /// width while the REAL space is narrower: horizontal text overflow and,
    /// when the overflows of several elements pile up vertically (extra lines
    /// not counted in the reserved height), real overlap between elements.
    /// Forces the "legacy" style explicitly (`NSScroller.preferredScrollerStyle`
    /// depends on the hardware attached to the shared machine, not controllable
    /// from here) for a deterministic reproduction.
    @Test("card tall enough to show the scroll bar (legacy style): no overlapping element")
    func itemsDoNotOverlapWhenScrollerAppears() throws {
        let (model, items) = try makeModelWithHiraiCard()
        var collected: [Int: CGRect] = [:]
        // Deliberately short viewport (a typical right panel is ~600+ pt tall,
        // here 260 pt): the whole card (4 elements, ~700-800 pt) certainly exceeds
        // the viewport, so the vertical bar certainly appears.
        let viewportSize = CGSize(width: 320, height: 260)
        let hostingView = NSHostingView(rootView:
            RewriteScrollHost(model: model) {
                CardItemsProbe(items: items, model: model, blockId: "hirai") { collected = $0 }
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
        )
        hostingView.frame = CGRect(origin: .zero, size: viewportSize)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = hostingView

        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let scrollView = try #require(model.rewriteScrollView, "RewriteScrollHost.makeNSView must wire up model.rewriteScrollView")
        scrollView.scrollerStyle = .legacy // deterministic reproduction, see comment above
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        exportPNG(hostingView, to: outputRoot.appendingPathComponent("card-overlap-legacy-scroller.png"))

        let frames = (0 ..< items.count).map { collected[$0] ?? .zero }
        #expect(frames.allSatisfy { $0.height > 0 }, "an element has height 0 with the legacy bar: \(frames)")
        #expect(scrollView.contentView.bounds.width < viewportSize.width, "the legacy bar should reduce the width of contentView (otherwise this test is not really reproducing the condition)")
        for i in 0 ..< frames.count {
            for j in (i + 1) ..< frames.count where j > i {
                let a = frames[i], b = frames[j]
                #expect(!a.intersects(b), "elements \(i) and \(j) overlap with the legacy bar: \(a) vs \(b)")
                if a.intersects(b) {
                    // Element width against the real available width: confirms whether the
                    // text was shaped for a wider width than the real one after the bar
                    // appeared.
                    print("DEBUG contentView width=\(scrollView.contentView.bounds.width) item\(i)=\(a) item\(j)=\(b)")
                }
            }
        }
    }

    @Test("panel resize (520→320 pt) on the SAME view leaves no overlapping elements")
    func itemsDoNotOverlapAfterLiveResize() throws {
        let (model, items) = try makeModelWithHiraiCard()
        var collected: [Int: CGRect] = [:]
        let probe = CardItemsProbe(items: items, model: model, blockId: "hirai") { collected = $0 }
            .background(Color.white)
        let hosting = NSHostingView(rootView: AnyView(probe))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = [.intrinsicContentSize] // same option as RewriteScrollHost.swift

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)

        let outerFrame = NSView(frame: CGRect(x: 0, y: 0, width: 520, height: 900))
        outerFrame.translatesAutoresizingMaskIntoConstraints = false
        outerFrame.addSubview(container)

        let window = NSWindow(contentRect: outerFrame.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = outerFrame

        let widthConstraint = container.widthAnchor.constraint(equalToConstant: 520)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            widthConstraint,
            container.topAnchor.constraint(equalTo: outerFrame.topAnchor),
            container.leadingAnchor.constraint(equalTo: outerFrame.leadingAnchor),
        ])

        outerFrame.layoutSubtreeIfNeeded()
        outerFrame.layoutSubtreeIfNeeded()
        let framesAt520 = (0 ..< items.count).map { collected[$0] ?? .zero }
        #expect(framesAt520.allSatisfy { $0.height > 0 }, "height 0 at 520 pt (test setup, not yet the resize): \(framesAt520)")

        // The "resize": only the constraint changes, no new
        // `NSHostingView`/`rootView` — exactly what happens when the real window
        // changes width and `WindowLayoutMath` recomputes `rightPanelWidth`
        // (SwiftUI updates `RewritePanel`/`BlockCardView`, but
        // `RewriteScrollHost.updateNSView` NEVER touches the constraints of
        // `container`, created only once in `makeNSView`).
        widthConstraint.constant = 320
        hosting.invalidateIntrinsicContentSize()
        hosting.rootView = AnyView(probe) // same reassignment as RewriteScrollHost.updateNSView
        outerFrame.layoutSubtreeIfNeeded()
        outerFrame.layoutSubtreeIfNeeded()

        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        exportPNG(hosting, to: outputRoot.appendingPathComponent("card-overlap-resized-520-to-320pt.png"))

        let framesAfterResize = (0 ..< items.count).map { collected[$0] ?? .zero }
        #expect(framesAfterResize.allSatisfy { $0.height > 0 }, "an element has height 0 after resizing to 320 pt: \(framesAfterResize)")
        for i in 0 ..< framesAfterResize.count {
            for j in (i + 1) ..< framesAfterResize.count where j > i {
                let a = framesAfterResize[i], b = framesAfterResize[j]
                #expect(!a.intersects(b), "elements \(i) and \(j) overlap after the 520→320 pt resize: \(a) vs \(b) (before the resize: \(framesAt520[i]) / \(framesAt520[j]))")
            }
        }
    }

    @Test("320/392/520 pt: the card's elements (paragraph/table/paragraph) never overlap", arguments: [CGFloat(320), CGFloat(392), CGFloat(520)])
    func itemsDoNotOverlap(panelWidth: CGFloat) throws {
        let (frames, totalHeight, _) = try measure(panelWidth: panelWidth, pngName: "card-overlap-\(Int(panelWidth))pt.png")

        #expect(frames.allSatisfy { $0.height > 0 }, "an element has height 0 at \(panelWidth) pt: \(frames)")

        for i in 0 ..< frames.count {
            for j in (i + 1) ..< frames.count where j > i {
                let a = frames[i], b = frames[j]
                #expect(!a.intersects(b), "elements \(i) and \(j) overlap at \(panelWidth) pt: \(a) vs \(b)")
            }
        }

        // Sum of the heights (plus the 8 pt spacing between `CardContainer`
        // elements, design spec) against the total content height: a total height
        // SMALLER than the sum would mean the elements are squeezed on top of each
        // other (an indirect measure of the same cause as the overlap).
        let spacing: CGFloat = 8 * CGFloat(max(0, frames.count - 1))
        let sumOfItemHeights = frames.reduce(0) { $0 + $1.height } + spacing
        let contentHeight = (frames.map(\.maxY).max() ?? 0) - (frames.map(\.minY).min() ?? 0)
        #expect(abs(contentHeight - sumOfItemHeights) < 2, "the content height (\(contentHeight)) does not match the sum of the elements (\(sumOfItemHeights)) a \(panelWidth) pt — a sign of overlapping or wrongly spaced elements")
        _ = totalHeight
    }
}
}
