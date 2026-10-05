import AppKit
import Foundation
import Testing
@preconcurrency import PDFKit
@testable import LelePdf

/// Integration for the "highlighter like Preview" behavior
/// (`AnnotationTextMarkupToggle` + `AnnotationTextMarkupCreator`): REAL
/// PDFKit selections (`page.selection(for: range:)`, same technique as
/// `ReviewM7bTests`/`AnnotationTextRangeResolverTests`) and a real mouse
/// gesture (`AnnotationRealEventHarness`, `NSWindow.sendEvent`) for the
/// drag path. Covers: mark/unmark, splitting in the middle of a mark, no
/// stacking with a different color, the rule for mixed selections, a single
/// ⌘Z for the whole operation, marks written into the PDF and those
/// imported from Preview.
extension HeavyTestSuites {
@MainActor
@Suite("highlighter/underline/strikethrough are removed by going over them again, like Preview", .serialized)
struct AnnotationTextMarkupToggleRealEventTests {
    // Text made of distinct words, so precise sub-ranges can be selected
    // with `NSRange` without search ambiguity.
    private static let text = "Uno due tre quattro cinque sei sette otto nove dieci"

    private func makeController(document: PDFDocument, pageCount: Int = 1) async -> AnnotationController {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfF13Tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DocumentStore(dataFolderURL: dir)
        let fingerprint = "fp-f13-\(UUID().uuidString)"
        _ = await store.registerDocument(fingerprint: fingerprint, byteHash: nil, fileName: "a.pdf", lastKnownPath: "/tmp/a.pdf", title: "A", pageCount: pageCount)
        let controller = AnnotationController(store: store)
        controller.load(fingerprint: fingerprint, items: [])
        return controller
    }

    private func selection(_ document: PDFDocument, _ range: NSRange, page: Int = 0) throws -> PDFSelection {
        let pdfPage = try #require(document.page(at: page))
        return try #require(pdfPage.selection(for: range))
    }

    // MARK: - 1. Mark / unmark with a real drag gesture (NSWindow.sendEvent)

    @Test("a real drag over the SAME phrase highlights it, a second identical drag removes it")
    func realDragTogglesHighlightOnThenOff() throws {
        let scene = try AnnotationRealEventHarness(windowState: .fresh, withMark: false, insideAnalyzedSection: false)
        defer { scene.teardown() }
        let controller = scene.model.annotationController
        controller.barVisible = true
        controller.selectTool(.highlight)
        let range = try scene.textDragRange()

        scene.drag(from: range.start, to: range.end)
        #expect(controller.annotations.count == 1, "the first drag over unmarked text must highlight")
        let created = try #require(controller.annotations.first)
        #expect(created.kind == .highlight)

        scene.drag(from: range.start, to: range.end)
        #expect(controller.annotations.isEmpty, "going over the SAME text with the same tool must remove the mark, not darken it")

        // A single ⌘Z restores exactly the mark removed by the second drag
        // (undoable with ONE ⌘Z).
        #expect(controller.performUndo())
        #expect(controller.annotations.count == 1)
        #expect(controller.annotations.first?.id == created.id)
    }

    // MARK: - 2. Splitting in the middle of a mark (real PDFKit selection, no window)

    @Test("unmarking the MIDDLE of a mark splits it into two annotations, restored together by a single ⌘Z")
    func partialOverlapInTheMiddleSplitsIntoTwoAnnotations() async throws {
        let url = try StoreFixtures.makeTextPDF(text: Self.text, fileName: "f13-split.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let controller = await makeController(document: document)

        // "Uno due tre quattro cinque..." — highlight the first 4 words (a wide
        // range), then unmark only "due tre" in the middle.
        let fullRange = NSRange(location: 0, length: 19) // "Uno due tre quattro"
        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: try selection(document, fullRange), document: document, controller: controller)
        #expect(controller.annotations.count == 1)
        let originalId = try #require(controller.annotations.first?.id)

        let middleRange = NSRange(location: 4, length: 7) // "due tre"
        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: try selection(document, middleRange), document: document, controller: controller)

        #expect(controller.annotations.count == 2, "unmarking the middle must leave TWO pieces (no stacking, no total deletion)")
        #expect(controller.annotations.contains { $0.id == originalId }, "the initial piece keeps the SAME id (only shortened)")
        for annotation in controller.annotations {
            #expect(annotation.kind == .highlight)
            #expect(!(annotation.quads ?? []).isEmpty, "every piece must have recomputed geometry")
            let range = try #require(annotation.textRange)
            let overlapsRemovedMiddle = range.start < (middleRange.location + middleRange.length)
                && (range.start + range.length) > middleRange.location
            #expect(!overlapsRemovedMiddle, "no remaining piece may cover the removed stretch")
        }

        // ONE ⌘Z for the whole operation (even with a split): back to the single
        // original mark, same id.
        #expect(controller.performUndo())
        #expect(controller.annotations.count == 1)
        #expect(controller.annotations.first?.id == originalId)
        #expect(controller.annotations.first?.textRange?.length == fullRange.length)
    }

    // MARK: - 3. No stacking with a different color

    @Test("marking with a different color over already highlighted text ABSORBS it: a single mark, never two overlapping")
    func markingWithADifferentColorMergesInsteadOfStacking() async throws {
        let url = try StoreFixtures.makeTextPDF(text: Self.text, fileName: "f13-no-stack.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let controller = await makeController(document: document)

        let yellow = AnnotationColor(red: 1, green: 0.9, blue: 0.25, alpha: 0.55)
        let green = AnnotationColor(red: 0.5, green: 0.9, blue: 0.4, alpha: 0.55)

        // First highlight (mini bar: explicit color), then a second one that
        // STARTS outside the existing mark but crosses it — the anchor is on
        // unmarked text → mark mode, so the old mark is absorbed, not overlapped.
        AnnotationTextMarkupCreator.apply(
            kind: .highlight, selection: try selection(document, NSRange(location: 4, length: 7)), // "due tre"
            document: document, controller: controller, color: yellow
        )
        #expect(controller.annotations.count == 1)

        AnnotationTextMarkupCreator.apply(
            kind: .highlight, selection: try selection(document, NSRange(location: 0, length: 19)), // "Uno due tre quattro"
            document: document, controller: controller, color: green
        )

        #expect(controller.annotations.count == 1, "NEVER a second layer of the same tool over the same text")
        let merged = try #require(controller.annotations.first)
        #expect(merged.color == green, "the single mark takes the color of the current operation, not the absorbed one")
        #expect(merged.textRange?.start == 0)
        #expect(merged.textRange?.length == 19)
    }

    // MARK: - 4. Mixed-selection rule (the author's proposal, confirmed)

    @Test("a mixed selection that STARTS on marked text: unmarks throughout the selection, creates nothing where there was no mark already")
    func mixedSelectionStartingOnMarkedTextUnmarksThroughout() async throws {
        let url = try StoreFixtures.makeTextPDF(text: Self.text, fileName: "f13-mixed-unmark.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let controller = await makeController(document: document)

        // Highlight "Uno due tre" (0..<11), then select from inside that mark
        // ("due", position 4) to a stretch NEVER marked further on ("quattro
        // cinque").
        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: try selection(document, NSRange(location: 0, length: 11)), document: document, controller: controller)
        let originalId = try #require(controller.annotations.first?.id)

        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: try selection(document, NSRange(location: 4, length: 23)), document: document, controller: controller)

        // The start (position 4) was marked → the WHOLE operation unmarks: the
        // existing mark is shortened (keeps only "Uno "), and the part of the
        // selection never marked ("quattro cinque...") does not generate any new
        // highlight.
        #expect(controller.annotations.count == 1, "in unmark mode nothing new is ever created")
        let remaining = try #require(controller.annotations.first)
        #expect(remaining.id == originalId)
        #expect(remaining.textRange?.start == 0)
        #expect(remaining.textRange?.length == 4) // "Uno "
    }

    @Test("a mixed selection that STARTS on unmarked text: marks the whole selection, absorbing the mark it crosses")
    func mixedSelectionStartingOnUnmarkedTextMarksThroughout() async throws {
        let url = try StoreFixtures.makeTextPDF(text: Self.text, fileName: "f13-mixed-mark.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let controller = await makeController(document: document)

        // Highlight "tre" (8..<11), then select from BEFORE the mark (position 0,
        // unmarked) to AFTER it.
        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: try selection(document, NSRange(location: 8, length: 3)), document: document, controller: controller)
        #expect(controller.annotations.count == 1)

        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: try selection(document, NSRange(location: 0, length: 19)), document: document, controller: controller)

        #expect(controller.annotations.count == 1, "the crossed mark must be absorbed into the single highlight, not left apart")
        #expect(controller.annotations.first?.textRange?.start == 0)
        #expect(controller.annotations.first?.textRange?.length == 19)
    }

    // MARK: - 5. Works with marks imported from Preview

    @Test("a highlight imported from Preview (without a textRange in the PDF) is removed by going over it again")
    func togglingWorksOnAPreviewImportedHighlight() async throws {
        let url = try StoreFixtures.makeTextPDF(text: Self.text, fileName: "f13-imported.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))

        // A "Preview" highlight: no LelePdf signature, only the standard PDF
        // color/rect — same factory as
        // `PDFAnnotationWriteServiceTests.addPreviewHighlight`.
        let previewRange = try #require(page.selection(for: NSRange(location: 0, length: 19))) // "Uno due tre quattro"
        let previewAnnotation = PDFAnnotation(bounds: previewRange.bounds(for: page), forType: .highlight, withProperties: nil)
        previewAnnotation.color = .systemYellow
        previewAnnotation.userName = "Anteprima"
        page.addAnnotation(previewAnnotation)

        let imported = PDFAnnotationImporter.readAndDetachOwned(from: document)
        let annotation = try #require(imported.external.first)
        #expect(annotation.kind == .highlight)
        #expect(annotation.textRange != nil, "an imported annotation must have a textRange resolved from the geometry, otherwise it cannot be unmarked")

        let controller = await makeController(document: document)
        controller.load(fingerprint: "fp-imported", items: [annotation])

        // Selecting the same stretch again (the anchor falls inside the imported
        // highlight) must REMOVE it.
        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: try selection(document, NSRange(location: 0, length: 19)), document: document, controller: controller)
        #expect(controller.annotations.isEmpty, "a mark imported from Preview must be removable like one created by LelePdf")
    }

    // MARK: - 6. Works with marks written into the PDF

    @Test("a highlight saved into the PDF and reopened in a second window is removed by going over it again")
    func togglingWorksAfterAPDFRoundTrip() async throws {
        let url = try StoreFixtures.makeTextPDF(text: Self.text, fileName: "f13-roundtrip.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let firstData = try Data(contentsOf: url)
        let firstModel = try #require(DocumentModel(document: PDFFileDocument(data: firstData, displayName: url.lastPathComponent), fileURL: url))
        PipelineRunner.run(model: firstModel)
        await waitUntil { firstModel.storeFingerprint != nil }
        // Margin for the same reason as `PDFAnnotationWriteServiceTests.
        // roundTripThroughDocumentModelHasNoDuplicateAnnotations`: as soon as the
        // fingerprint arrives, the asynchronous loading of `annotazioni.json`
        // (empty for a new document, `AnnotationController.load`) may still be in
        // progress, which would otherwise reset `annotations` AFTER the highlight
        // below has been created — a race observed in this suite under the load of
        // the whole test battery (886 tests), not reproduced when running the
        // suite on its own.
        try await Task.sleep(for: .milliseconds(200))

        let selection1 = try selection(firstModel.pdfDocument, NSRange(location: 0, length: 19))
        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: selection1, document: firstModel.pdfDocument, controller: firstModel.annotationController)
        #expect(firstModel.annotationController.annotations.count == 1)
        try await Task.sleep(for: .milliseconds(250))

        firstModel.saveMarksIntoPDF()
        if case .failed(let message) = firstModel.pdfSaveState { Issue.record("write into the PDF failed: \(message)") }
        firstModel.flushStore()
        try await Task.sleep(for: .milliseconds(300))

        let secondData = try Data(contentsOf: url)
        let secondModel = try #require(DocumentModel(document: PDFFileDocument(data: secondData, displayName: url.lastPathComponent), fileURL: url))
        PipelineRunner.run(model: secondModel)
        await waitUntil { secondModel.storeFingerprint != nil }
        try await Task.sleep(for: .milliseconds(200))

        let reloaded = try #require(secondModel.annotationController.annotations.first { $0.kind == .highlight })
        #expect(reloaded.textRange != nil, "a LelePdf annotation read back from annotazioni.json must still have its textRange")

        AnnotationTextMarkupCreator.apply(
            kind: .highlight, selection: try selection(secondModel.pdfDocument, NSRange(location: 0, length: 19)),
            document: secondModel.pdfDocument, controller: secondModel.annotationController
        )
        #expect(!secondModel.annotationController.annotations.contains { $0.kind == .highlight }, "a mark written into the PDF and read back must be removable like one created in this session")
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - 7. Visual check (before/after PNG)

    @Test("before/after PNG: the page shows the highlight color after marking, and goes back to how it was after removing it")
    func screenshotBeforeAfterMarkAndUnmark() async throws {
        let url = try StoreFixtures.makeTextPDF(text: Self.text, fileName: "f13-screenshot.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let controller = await makeController(document: document)
        let renderer = AnnotationRenderer(document: document)

        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let size = CGSize(width: 300, height: 200)

        func samplePixel(_ image: NSImage, xFraction: CGFloat, yFraction: CGFloat) -> NSColor? {
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            let x = min(Int(CGFloat(bitmap.pixelsWide) * xFraction), bitmap.pixelsWide - 1)
            let y = min(Int(CGFloat(bitmap.pixelsHigh) * yFraction), bitmap.pixelsHigh - 1)
            return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        }
        func savePNG(_ image: NSImage, name: String) throws {
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                Issue.record("cannot serialize the PNG \(name)")
                return
            }
            try png.write(to: outputRoot.appendingPathComponent(name))
        }

        // The text is drawn at (20, 150) on a 300×200 pt page
        // (`StoreFixtures.makeTextPDF`): a point inside "Uno" stays a good
        // sample, above/below unaffected by the shorter highlights used elsewhere
        // in this file.
        let sampleX: CGFloat = 25.0 / size.width
        let sampleY: CGFloat = 1 - (150.0 / size.height)

        let before = page.thumbnail(of: size, for: .mediaBox)
        try savePNG(before, name: "f13-1-prima.png")
        let beforeColor = try #require(samplePixel(before, xFraction: sampleX, yFraction: sampleY))

        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: try selection(document, NSRange(location: 0, length: 3)), document: document, controller: controller)
        renderer.refreshAll(controller.annotations)
        let after = page.thumbnail(of: size, for: .mediaBox)
        try savePNG(after, name: "f13-2-evidenziato.png")
        let afterColor = try #require(samplePixel(after, xFraction: sampleX, yFraction: sampleY))

        AnnotationTextMarkupCreator.apply(kind: .highlight, selection: try selection(document, NSRange(location: 0, length: 3)), document: document, controller: controller)
        renderer.refreshAll(controller.annotations)
        let removed = page.thumbnail(of: size, for: .mediaBox)
        try savePNG(removed, name: "f13-3-tolto.png")
        let removedColor = try #require(samplePixel(removed, xFraction: sampleX, yFraction: sampleY))

        // REAL re-read from disk (not the in-memory `NSImage`s), like
        // `AnnotationDeleteButtonScreenshotTests`.
        for name in ["f13-1-prima.png", "f13-2-evidenziato.png", "f13-3-tolto.png"] {
            let data = try Data(contentsOf: outputRoot.appendingPathComponent(name))
            #expect(data.count > 200, "\(name): re-read PNG suspiciously small")
        }

        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
        }
        #expect(distance(beforeColor, afterColor) > 0.05, "the color must visibly change after highlighting")
        #expect(distance(afterColor, removedColor) > 0.05, "the color must change again after removing the mark")
        #expect(distance(beforeColor, removedColor) < 0.05, "after removing it the pixel must go back close to how it was BEFORE (removed, not darkened)")
    }
}
}
