import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// F5A (the author's feedback after trying F4):
/// - **Sidebar layout**: the author preferred the earlier left menu and
///   disliked the split with one part above and one below; they asked to put
///   it back as before and to keep the color dot beside "Map". The sidebar
///   goes back to three tabs in a row (Pages/Contents/Map) plus the color
///   dot, instead of the contents always on top above a two-option
///   segmented control.
/// - **Color menu**: the color menu that appears from the left misbehaved:
///   after selecting a color the popup menu disappeared but the floating
///   color selection stayed open. The legend's hue picker is no longer a
///   native `Picker` (see `SidebarLegendOverlay.swift`).
/// - **Colors**: the colors were all shades of blue, that is, even when the
///   label said red, the dot in the legend was a shade of blue. Same native
///   `Picker` as above: macOS re-tints its icons with the accent color.
///   Verified here by sampling the dots' pixels rather than trusting the
///   code.
///
/// Visual check of the REAL views (`Sidebar`, `ChaptersSidebar`,
/// `LegendOverlayPanel`, `ColorThemePickerList`), same `exportPNG` harness as
/// `CardItemOverlapTests`/`BulletsSubItemsRenderTests`; PNGs in
/// `~/Library/Caches/LelePdf/verifica-screenshots/`, read back after the
/// export.
extension HeavyTestSuites {
@MainActor
@Suite("F5A: three-tab sidebar, legend and color menu · visual check", .serialized)
struct SidebarIndexLegendRenderTests {
    private static let outputRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)

    /// A realistic T1-T4 tree: a long T1 (must stop at a TRAILING ellipsis,
    /// never mid-word), T2/T3/T4 nested on the current page (with
    /// `currentPage: 1` the "current" entry according to
    /// `TocNavigation.currentEntry` is t4, the last one with page <= 1 in
    /// document order; it must be highlighted with the subject color, not a
    /// fixed light blue), plus a manual entry ("hand" icon).
    private func makeModel(hue: MaterialHue, currentPage: Int) throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per l'indice.", fileName: "index-render-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "index-render-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
        model.setColorTheme(hue)
        model.tocSource = .generated
        model.tocEntries = [
            TocEntry(id: "t1", title: "Capitolo 1 · Introduzione generale al sistema previdenziale e alle sue molte eccezioni regionali", level: 1, page: 0),
            TocEntry(id: "t2", title: "1.1 Il quadro normativo", level: 2, page: 1),
            TocEntry(id: "t3", title: "1.1.1 Le fonti primarie", level: 3, page: 1),
            TocEntry(id: "t4", title: "1.1.1.a A very specific detail added by hand while reading", level: 4, page: 1, origin: .manual),
            TocEntry(id: "t5", title: "1.2 Le eccezioni regionali", level: 2, page: 2),
            TocEntry(id: "t6", title: "Capitolo 2 · Conclusioni", level: 1, page: 3),
        ]
        model.currentPageIndex = currentPage
        return model
    }

    // The window goes back to the caller together with the view (no longer
    // closed in here): closing it at the end of THIS function, as the
    // original automatic insertion did, detached `hostingView` from the
    // window BEFORE `exportPNG`/`pixelColor` captured it, producing a bitmap
    // without real SwiftUI content (found by `chaptersSidebarIsReadable`,
    // which samples colors: "found" always failed). Each caller closes its
    // own window at the end of the test.
    private func host(_ view: some View, width: CGFloat, height: CGFloat) -> (view: NSHostingView<AnyView>, window: NSWindow) {
        let hostingView = NSHostingView(rootView: AnyView(view.frame(width: width, height: height, alignment: .top)))
        hostingView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        return (hostingView, window)
    }

    /// The restored layout, on both tabs the author contrasted in the
    /// feedback ("pages, contents, map" in a row): a single three-option
    /// segmented control plus the color dot beside it, never a panel on top
    /// and a two-option control below.
    @Test(
        "Sidebar: three tabs in a row (Pages/Contents/Map) plus the color dot, no longer contents on top and two tabs below",
        arguments: [SidebarTab.pagine, SidebarTab.indice, SidebarTab.mappa]
    )
    func sidebarRestoresThreeTabRow(tab: SidebarTab) throws {
        let model = try makeModel(hue: .blu, currentPage: 1)
        model.sidebarTab = tab
        let view = Sidebar().environment(model)
        let (hostingView, window) = host(view, width: 264, height: 520)
        defer { closeTestWindow(window) }
        exportPNG(hostingView, to: Self.outputRoot.appendingPathComponent("sidebar-three-tabs-\(tab.rawValue).png"))
        #expect(hostingView.fittingSize.height > 0)
    }

    /// Quality criterion 5.3 "readable at sidebar widths 200-360 pt": the two
    /// extreme widths, plus the default blue and a second color (green) for
    /// criterion 6.1 "a single subject color ... used everywhere ...
    /// contents": the same view with two different hues must show two
    /// different highlights, never a fixed light blue. This content moved
    /// from `IndexPanel` (a panel always on top) to `ChaptersSidebar` (the
    /// "Contents" tab), without touching its internal drawing.
    @Test(
        "Contents tab 200-360pt: T1-T4 readable, current row highlighted with the subject color",
        arguments: [(CGFloat(200), MaterialHue.blu), (CGFloat(360), MaterialHue.verde)]
    )
    func chaptersSidebarIsReadable(width: CGFloat, hue: MaterialHue) throws {
        let model = try makeModel(hue: hue, currentPage: 1)
        let view = ChaptersSidebar().environment(model)
        let (hostingView, window) = host(view, width: width, height: 260)
        defer { closeTestWindow(window) }
        exportPNG(hostingView, to: Self.outputRoot.appendingPathComponent("chapters-sidebar-\(Int(width))pt-\(hue.rawValue).png"))

        // Automatic check, not just by eye: the current row (here t4, the
        // last one with page <= 1 in document order, see
        // `TocNavigation.currentEntry`) must have a colored background
        // derived from the chosen hue, neither transparent nor a fixed light
        // blue independent of `hue`. The central column is scanned instead of
        // a fixed point: the exact height of the header is not contractual,
        // and a hand-guessed fixed point has already proven fragile (it
        // landed on a non-highlighted row). Same principle already chosen in
        // `ChatOverlayCompositionTests` ("reading a single pixel depends on
        // coordinate conventions that are not guaranteed").
        let expected = NSColor(DSColor.markColors(for: .rectangle, hue: hue).fill.opacity(0.75))
        let found = (0...100).contains { step in
            guard let sampled = pixelColor(in: hostingView, atFractionX: 0.5, fractionY: CGFloat(step) / 100) else { return false }
            return colorsClose(sampled, expected)
        }
        #expect(found, "no row at \(width)pt/\(hue.rawValue) shows the expected highlighted background ~\(expected)")
    }

    @Test("Floating legend: 4 marks in the subject color and the Subject color selector (button, no longer a native Picker)")
    func legendOverlayPanelRendersMarksAndSelector() throws {
        let model = try makeModel(hue: .ambra, currentPage: 0)
        let binding = Binding(get: { model.colorTheme }, set: { model.setColorTheme($0) })
        let colorPickerOpen = Binding.constant(false)
        let view = LegendOverlayPanel(hue: model.colorTheme, colorTheme: binding, colorPickerOpen: colorPickerOpen)
        let (hostingView, window) = host(view, width: DSMetrics.legendPanelWidth, height: DSMetrics.legendPanelMaxHeight)
        defer { closeTestWindow(window) }
        exportPNG(hostingView, to: Self.outputRoot.appendingPathComponent("legend-overlay-panel.png"))
        #expect(hostingView.fittingSize.height > 0)
    }

    /// The exact bug reported by the author was in the entries of a native
    /// `Picker`, which macOS re-tints with the control's accent color
    /// regardless of the real hue. Here the dot of EVERY hue in the shared
    /// list is sampled (`ColorThemePickerList`, now used by both
    /// `ColorThemeSwatchButton` and `LegendOverlayPanel` in place of the
    /// `Picker`) and each one is checked to resemble the hue it claims to
    /// represent, not a single shade of blue repeated 8 times.
    @Test("Hue list: each dot shows its own hue, not all blue")
    func colorThemePickerListShowsDistinctHues() throws {
        let model = try makeModel(hue: .blu, currentPage: 0)
        let selection = Binding(get: { model.colorTheme }, set: { model.setColorTheme($0) })
        let hues = MaterialHue.allCases
        let width: CGFloat = 160
        let height: CGFloat = CGFloat(hues.count) * 24
        let view = ColorThemePickerList(selection: selection)
        let (hostingView, window) = host(view, width: width, height: height)
        defer { closeTestWindow(window) }
        exportPNG(hostingView, to: Self.outputRoot.appendingPathComponent("color-theme-picker-list.png"))

        // The dot is at the left of each row (`Circle` at x≈12pt from the
        // button's left edge, `HStack(spacing: 8)` with horizontal padding 6,
        // see `ColorThemePickerList`). The whole column is scanned instead of
        // guessing the exact row of each hue (same principle as
        // `chaptersSidebarIsReadable`: a hand-guessed fixed point has already
        // proven fragile, and here we also must not depend on the direction,
        // top-down or bottom-up, in which `NSBitmapImageRep` numbers rows): if
        // the dot of a hue appears NOWHERE in the column, either the
        // rendering is broken or that row does not exist with that color,
        // exactly the original symptom (the dot "is a shade of blue" even
        // when the label says another color).
        let sampleX: CGFloat = 12 / width
        var closestMatchByHue: [MaterialHue: (color: NSColor, distance: CGFloat)] = [:]
        for hue in hues {
            let expected = NSColor(DSColor.markColor(hue: hue, tone: .t4))
            guard let expectedRGB = expected.usingColorSpace(.deviceRGB) else { continue }
            var best: (color: NSColor, distance: CGFloat)?
            // Also scanned horizontally across the dot (not a single
            // column): with a single `sampleX` the sampled pixel can land on
            // the anti-aliased edge and skew the distance, a fragility
            // actually seen when this was first merged.
            let sampleXs = stride(from: sampleX - 4 / width, through: sampleX + 4 / width, by: 2 / width)
            for x in sampleXs {
                for step in 0...200 {
                    guard let sampled = pixelColor(in: hostingView, atFractionX: x, fractionY: CGFloat(step) / 200),
                          let sampledRGB = sampled.usingColorSpace(.deviceRGB) else { continue }
                    let distance = abs(sampledRGB.redComponent - expectedRGB.redComponent)
                        + abs(sampledRGB.greenComponent - expectedRGB.greenComponent)
                        + abs(sampledRGB.blueComponent - expectedRGB.blueComponent)
                    if best == nil || distance < best!.distance { best = (sampled, distance) }
                }
            }
            guard let best else {
                Issue.record("no sampleable pixel for \(hue.rawValue)")
                continue
            }
            closestMatchByHue[hue] = best
            #expect(best.distance < 0.24, "no row shows the expected dot for \(hue.label) (~\(expected)); the closest found is \(best.color) at distance \(best.distance)")
        }

        // Direct guard on the author's complaint ("even when it says red, the
        // dot is a shade of blue"): red and blue must not only be within a
        // tolerance, the dominant channel must be the right one: red redder
        // than blue, blue bluer than red.
        if let rosso = closestMatchByHue[.rosso]?.color.usingColorSpace(.deviceRGB),
           let blu = closestMatchByHue[.blu]?.color.usingColorSpace(.deviceRGB) {
            #expect(rosso.redComponent > blu.redComponent, "the \"red\" dot is not redder than the \"blue\" dot: \(rosso) vs \(blu)")
            #expect(blu.blueComponent > rosso.blueComponent, "the \"blue\" dot is not bluer than the \"red\" dot: \(blu) vs \(rosso)")
        } else {
            Issue.record("missing sample for red/blue, cannot compare channels")
        }
    }

    // MARK: - Pixel reading (automatic color check, not just eyeballing the PNG)

    private func pixelColor(in view: NSView, atFractionX fx: CGFloat, fractionY fy: CGFloat) -> NSColor? {
        // Temporary capture bitmap, freed immediately (see `exportPNG`
        // in CardItemOverlapTests.swift, same reason).
        autoreleasepool {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let x = Int(CGFloat(bitmap.pixelsWide) * fx)
            let y = Int(CGFloat(bitmap.pixelsHigh) * fy)
            return bitmap.colorAt(x: x, y: y)
        }
    }

    private func colorsClose(_ a: NSColor, _ b: NSColor, tolerance: CGFloat = 0.12) -> Bool {
        guard let a = a.usingColorSpace(.deviceRGB), let b = b.usingColorSpace(.deviceRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < tolerance
            && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }
}
}
