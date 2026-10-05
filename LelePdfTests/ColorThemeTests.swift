import Foundation
import AppKit
import Testing
@testable import LelePdf

/// SPEC §5.4 v2.6 "Color per subject": completeness and legibility of the
/// palette (`MaterialHue`/`MaterialTone`/`MaterialMarkTones`, pure), the
/// default color in Settings and the states (repeat/linked/selected)
/// computed on the same hue.
@Suite("Subject color: palette")
struct MaterialPaletteTests {
    @Test("at least 8 hues, all distinct")
    func atLeastEightDistinctHues() {
        #expect(MaterialHue.allCases.count >= 8)
        let degrees = Set(MaterialHue.allCases.map { $0.hueDegrees })
        #expect(degrees.count == MaterialHue.allCases.count, "two hues cannot share the same angle")
    }

    @Test("the default color is blue")
    func defaultHueIsBlu() {
        #expect(MaterialHue.default == .blu)
    }

    @Test("5 tones, from lightest to darkest")
    func tonesAreMonotonicallyDarker() {
        #expect(MaterialTone.allCases.count >= 4)
        let sorted = MaterialTone.allCases.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            #expect(a.brightness > b.brightness, "\(a) must be lighter than \(b)")
        }
        #expect(MaterialTone.t1.brightness > 0.85, "t1 (rectangle fill) must stay light")
        #expect(MaterialTone.t5.brightness < 0.4, "t5 (arrow/text) must stay dark")
        #expect(MaterialTone.t1.saturationMultiplier < MaterialTone.t2.saturationMultiplier)
        #expect(MaterialTone.t2.saturationMultiplier < MaterialTone.t3.saturationMultiplier)
    }

    @Test("tone assignment for the 4 marks (SPEC §5.4 v2.6)")
    func toneAssignmentMatchesSpec() {
        // "rectangle = light fill with medium border"
        let rectangle = MaterialMarkTones.assignment(for: .rectangle)
        #expect(rectangle.fill == .t1)
        #expect(rectangle.stroke == .t3)
        // "circle = medium-dark stroke"
        #expect(MaterialMarkTones.assignment(for: .circle).stroke == .t4)
        // "underline = medium stroke"
        #expect(MaterialMarkTones.assignment(for: .underline).stroke == .t3)
        // "arrow = dark stroke"
        #expect(MaterialMarkTones.assignment(for: .arrow).stroke == .t5)
        // The text (map chip, marked term) always stays legible, regardless
        // of the mark: always the darkest tone.
        for type in [MarkType.rectangle, .circle, .underline, .arrow] {
            #expect(MaterialMarkTones.assignment(for: type).text == .t5)
        }
    }

    @Test("contrast: border/underline (t3) and circle/arrow (t4/t5) stay legible on white, for every hue",
          arguments: MaterialHue.allCases)
    func contrastSanity(hue: MaterialHue) {
        func contrast(_ tone: MaterialTone) -> Double {
            MaterialColorMath.contrastAgainstWhite(
                hueDegrees: hue.hueDegrees,
                saturation: MaterialColorMath.saturation(hue: hue, tone: tone),
                brightness: tone.brightness
            )
        }
        // WCAG 1.4.11 (non-text graphical elements): 3:1.
        #expect(contrast(.t3) >= 3.0, "\(hue): border/underline barely visible on white")
        // WCAG 1.4.3 (text): 4.5:1, also applied to circle/arrow.
        #expect(contrast(.t4) >= 4.5, "\(hue): circle stroke barely legible on white")
        #expect(contrast(.t5) >= 4.5, "\(hue): arrow/text stroke barely legible on white")
        // The rectangle fill (t1) must stay clearly closer to white than the
        // other tones (SPEC "legible ... over the PDF text in multiply mode":
        // a fill that is too dark would cover the text beneath even under
        // multiply). This is a relative comparison, not an absolute
        // threshold: at full saturation some hues (purple, red) stay above
        // 3:1 even at the lightest tone, while still acting as a light
        // highlighter.
        #expect(contrast(.t1) < contrast(.t3), "\(hue): the rectangle fill is not clearly lighter than the border")
    }

    @Test("the rectangle is the only mark with a solid fill")
    func onlyRectangleHasFill() {
        for hue in MaterialHue.allCases {
            #expect(MarkPalette.colors(for: .rectangle, hue: hue).fill != .clear)
            #expect(MarkPalette.colors(for: .circle, hue: hue).fill == .clear)
            #expect(MarkPalette.colors(for: .underline, hue: hue).fill == .clear)
            #expect(MarkPalette.colors(for: .arrow, hue: hue).fill == .clear)
        }
    }

    @Test("two different hues produce different colors for the same mark")
    func differentHuesProduceDifferentColors() {
        let blu = MarkPalette.colors(for: .arrow, hue: .blu).stroke
        let rosso = MarkPalette.colors(for: .arrow, hue: .rosso).stroke
        #expect(blu != rosso)
    }

    @Test("the states (repeat/linked/selected) stay computed on the same hue")
    func stateTonesStayOnSameHue() {
        // SPEC: "The states ... stay as in §5.4, computed on the same hue".
        // `darkened(by:)` must darken the color WITHOUT changing its base
        // hue, for any `MaterialHue`.
        for hue in MaterialHue.allCases {
            let normal = MarkPalette.colors(for: .circle, hue: hue).stroke
            let hovered = normal.darkened(by: MarkGeometry.fillDarkenFraction(for: .hover))
            #expect(hovered != normal, "\(hue): the hover state must be visibly different")
            var nH: CGFloat = 0, nS: CGFloat = 0, nB: CGFloat = 0, nA: CGFloat = 0
            var hH: CGFloat = 0, hS: CGFloat = 0, hB: CGFloat = 0, hA: CGFloat = 0
            normal.usingColorSpace(.deviceRGB)?.getHue(&nH, saturation: &nS, brightness: &nB, alpha: &nA)
            hovered.usingColorSpace(.deviceRGB)?.getHue(&hH, saturation: &hS, brightness: &hB, alpha: &hA)
            #expect(hB < nB, "\(hue): hover must be darker than the normal state")
            #expect(hS > nS, "\(hue): hover must be more saturated than the normal state")
            #expect(abs(hH - nH) < 0.02, "\(hue): the hue must not change in the hover state")
        }
    }
}

/// Default color for new documents (SPEC §5.4 v2.6: "a default color for new
/// documents in Settings").
@Suite("Subject color: default preference")
struct DefaultColorThemePreferenceTests {
    // Isolated domain per test, never `AppRuntime.defaults` here: same
    // pattern as `PaneWidthStoreTests` (do not share state between tests in
    // the same process).
    private func isolatedDefaults() -> UserDefaults {
        let suite = "com.emanuele.LelePdf.tests.colortheme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("no saved preference: the app's default color (blue)")
    func startsWithAppDefault() {
        let defaults = isolatedDefaults()
        #expect(DefaultColorThemePreference.read(defaults: defaults) == .default)
    }

    @Test("saved preference: the one chosen in Settings")
    func readsSavedPreference() {
        let defaults = isolatedDefaults()
        defaults.set(MaterialHue.rosa.rawValue, forKey: DefaultColorThemePreference.defaultsKey)
        #expect(DefaultColorThemePreference.read(defaults: defaults) == .rosa)
    }

    @Test("an unrecognized value falls back to the default instead of failing the read")
    func unknownRawValueFallsBackToDefault() {
        let defaults = isolatedDefaults()
        defaults.set("colore-inesistente", forKey: DefaultColorThemePreference.defaultsKey)
        #expect(DefaultColorThemePreference.read(defaults: defaults) == .default)
    }
}

/// `documento.json`: `colorTheme` is persisted and honored by the `Store`
/// (SPEC §8, in addition to the Codable round trip in `RecordsCodableTests`).
@Suite("Subject color: DocumentStore")
struct DocumentStoreColorThemeTests {
    private func tempDataFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfColorThemeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("updateColorTheme writes documento.json and survives reopening")
    func updateColorThemePersists() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-colortheme"
        let registered = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: 3)
        #expect(registered.record.colorTheme == .default)

        await store.updateColorTheme(fingerprint: fingerprint, colorTheme: .ambra)
        await store.flush(fingerprint: fingerprint)

        let reopened = DocumentStore(dataFolderURL: dir)
        let loaded = await reopened.loadRecordAndAnalysis(fingerprint: fingerprint)
        #expect(loaded?.record.colorTheme == .ambra)
    }

    @Test("a new document immediately stores the Settings default")
    func newDocumentStoresInitialTheme() async throws {
        let dir = try tempDataFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-no-colortheme"
        _ = await store.registerDocument(
            fingerprint: fingerprint, byteHash: nil, fileName: "b.pdf",
            lastKnownPath: "/tmp/b.pdf", title: "B", pageCount: 3,
            initialColorTheme: .rosa
        )
        let record = await store.currentRecord(fingerprint: fingerprint)
        #expect(record?.colorTheme == .rosa)
    }

    @Test("the concurrent merge keeps a local colorTheme change")
    @MainActor
    func concurrentRecordMergeKeepsLocalThemeChange() {
        let baseline = StoreFixtures.sampleDocumentRecord(colorTheme: .blu)
        var local = baseline
        local.colorTheme = .rosso
        var disk = baseline
        disk.progress.lastReadPage = 9

        let merged = DocumentStore.mergeRecord(local: local, baseline: baseline, disk: disk)
        #expect(merged.colorTheme == .rosso)
        #expect(merged.progress.lastReadPage == 9)
    }
}
