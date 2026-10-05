import AppKit
import Foundation
import Testing
@preconcurrency import PDFKit
@testable import LelePdf

@Suite("Writing annotations into the PDF", .serialized)
@MainActor
struct PDFAnnotationWriteServiceTests {
    @Test("four marks and a free annotation reopen with the expected type, color, and page")
    func writesStandardAnnotations() throws {
        let url = try StoreFixtures.makeMultiPageTextPDF(pageCount: 4, fileName: "quattro-segni.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let originalData = try Data(contentsOf: url)
        let fingerprint = try #require(StoreFixtures.fingerprint(ofPDFAt: url))
        let marks = MarkType.allCasesForTests.enumerated().map { page, type in
            PDFMarkSnapshot(
                id: "b1:m\(page):p\(page)", page: page, type: type, text: "Segno \(page)",
                lineRects: [AnnotationRect(x: 30, y: 280, width: 100, height: 18)]
            )
        }
        let free = Annotation(
            id: "a1", page: 2, kind: .ink,
            color: AnnotationColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1),
            lineWidth: 3, rect: AnnotationRect(x: 40, y: 220, width: 80, height: 40),
            points: [AnnotationPoint(x: 40, y: 220), AnnotationPoint(x: 120, y: 260)]
        )

        let result = try PDFAnnotationWriteService.write(
            originalURL: url, marks: marks, freeAnnotations: [free], hue: .viola
        )
        #expect(result.backupCreated)
        #expect(try Data(contentsOf: result.backupURL) == originalData)

        let reopened = try #require(PDFDocument(url: url))
        #expect(DocumentFingerprint.compute(for: reopened) == fingerprint)
        let expectedTypes: [MarkType: PDFAnnotationSubtype] = [
            .rectangle: .highlight, .circle: .square, .underline: .underline, .arrow: .text,
        ]
        for (pageIndex, mark) in marks.enumerated() {
            let page = try #require(reopened.page(at: pageIndex))
            let annotation = try #require(page.annotations.first {
                PDFAnnotationOwnership.tag(of: $0) == .init(role: .mark, id: mark.id)
            })
            #expect(subtype(of: annotation) == expectedTypes[mark.type])
            expectSameRGB(annotation.color, PDFMarkAnnotationBuilder.color(for: mark.type, hue: .viola))
        }
        let freePage = try #require(reopened.page(at: 2))
        let writtenFree = try #require(freePage.annotations.first {
            PDFAnnotationOwnership.tag(of: $0) == .init(role: .freeAnnotation, id: "a1")
        })
        #expect(subtype(of: writtenFree) == .ink)
    }

    @Test("all free annotation kinds become standard PDF annotations")
    func writesEveryFreeAnnotationKind() throws {
        let url = try StoreFixtures.makeTextPDF(fileName: "annotazioni-libere.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let items = AnnotationKind.allCases.enumerated().map { index, kind in
            Annotation(
                id: "a\(index + 1)", page: 0, kind: kind,
                color: AnnotationPaletteColor.blue.color(alpha: kind == .highlight ? 0.55 : 1),
                fillColor: AnnotationPaletteColor.green.color(alpha: 0.25), lineWidth: 3,
                rect: AnnotationRect(x: Double(10 + index * 5), y: 40, width: 40, height: 24),
                quads: kind.isTextMarkup ? [AnnotationRect(x: 20, y: 145, width: 50, height: 16)] : nil,
                points: [AnnotationPoint(x: 20, y: 50), AnnotationPoint(x: 60, y: 70), AnnotationPoint(x: 40, y: 85)],
                text: "Annotazione \(index)", fontSize: 13
            )
        }
        _ = try PDFAnnotationWriteService.write(
            originalURL: url, marks: [], freeAnnotations: items, hue: .verdeAcqua
        )

        let reopened = try #require(PDFDocument(url: url))
        let page = try #require(reopened.page(at: 0))
        for item in items {
            let annotation = try #require(page.annotations.first {
                PDFAnnotationOwnership.tag(of: $0) == .init(role: .freeAnnotation, id: item.id)
            })
            #expect(standardSubtypeForFreeAnnotation(item.kind).contains(try #require(subtype(of: annotation))))
        }
    }

    @Test("backup created once and idempotent rewrite with no duplicates")
    func backupOnceAndNoDuplicates() throws {
        let url = try StoreFixtures.makeTextPDF(fileName: "idempotente.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try addPreviewHighlight(to: url)
        let dataBeforeLelePdf = try Data(contentsOf: url)
        let mark = PDFMarkSnapshot(
            id: "b1:m1:p0", page: 0, type: .rectangle, text: "Ciao",
            lineRects: [AnnotationRect(x: 20, y: 145, width: 35, height: 16)]
        )
        let free = Annotation(
            id: "a1", page: 0, kind: .note,
            color: AnnotationPaletteColor.yellow.color(),
            rect: AnnotationRect(x: 150, y: 120, width: 22, height: 22), text: "Nota LelePdf"
        )

        let first = try PDFAnnotationWriteService.write(
            originalURL: url, marks: [mark], freeAnnotations: [free], hue: .blu
        )
        let backupAfterFirstWrite = try Data(contentsOf: first.backupURL)
        #expect(backupAfterFirstWrite == dataBeforeLelePdf)
        let second = try PDFAnnotationWriteService.write(
            originalURL: url, marks: [mark], freeAnnotations: [free], hue: .blu
        )
        #expect(!second.backupCreated)
        #expect(try Data(contentsOf: second.backupURL) == backupAfterFirstWrite)

        let reopened = try #require(PDFDocument(url: url))
        let page = try #require(reopened.page(at: 0))
        let owned = page.annotations.compactMap(PDFAnnotationOwnership.tag(of:))
        #expect(owned.filter { $0.role == .mark }.count == 1)
        #expect(owned.filter { $0.role == .freeAnnotation }.count == 1)

        let imported = PDFAnnotationImporter.readAndDetachOwned(from: reopened)
        #expect(imported.external.count == 1)
        #expect(imported.external.first?.kind == .highlight)
        #expect(imported.recoveredFreeAnnotations.map(\.id) == ["a1"])
        #expect(imported.external.allSatisfy { $0.externalPDFIdentifier != nil })
    }

    @Test("an interruption before the replace leaves the original intact")
    func interruptedWriteKeepsOriginal() throws {
        enum SimulatedInterruption: Error { case now }
        let url = try StoreFixtures.makeTextPDF(fileName: "interrotto.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try Data(contentsOf: url)
        let mark = PDFMarkSnapshot(
            id: "b1:m1:p0", page: 0, type: .underline, text: "prova",
            lineRects: [AnnotationRect(x: 20, y: 145, width: 40, height: 16)]
        )

        #expect(throws: SimulatedInterruption.self) {
            try PDFAnnotationWriteService.write(
                originalURL: url, marks: [mark], freeAnnotations: [], hue: .verde,
                beforeReplace: { throw SimulatedInterruption.now }
            )
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(PDFDocument(url: url) != nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("if PDFKit changes the inner text, it saves an annotated copy and leaves the original byte-for-byte intact")
    func unstablePDFKitSerializationFallsBackToAnnotatedCopy() throws {
        let url = try StoreFixtures.makeTextPDF(fileName: "serializzazione-instabile.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try Data(contentsOf: url)
        let annotation = Annotation(
            id: "a1", page: 0, kind: .note,
            color: AnnotationPaletteColor.yellow.color(),
            rect: AnnotationRect(x: 100, y: 100, width: 22, height: 22),
            text: "Nota nella copia"
        )

        // Deterministically reproduces the guard that triggers on the real
        // Draghi PDF after `PDFDocument.dataRepresentation()`, without
        // writing to or copying that test PDF.
        let result = try PDFAnnotationWriteService.write(
            originalURL: url, marks: [], freeAnnotations: [annotation],
            hue: .blu, textIntegrityCheck: { _, _ in false }
        )

        #expect(!result.wroteOriginal)
        #expect(result.destinationURL == PDFAnnotationWriteService.annotatedCopyURL(for: url))
        #expect(try Data(contentsOf: url) == original)
        #expect(!result.backupCreated)
        #expect(!FileManager.default.fileExists(atPath: result.backupURL.path))
        let copy = try #require(PDFDocument(url: result.destinationURL))
        let page = try #require(copy.page(at: 0))
        #expect(page.annotations.contains {
            PDFAnnotationOwnership.tag(of: $0) == .init(role: .freeAnnotation, id: "a1")
        })
    }

    @Test("a folder error explains in English that the original is intact and what to do")
    func unwritableFolderHasActionableItalianMessage() throws {
        let underlying = CocoaError(.fileWriteNoPermission)
        let errors: [PDFAnnotationWriteError] = [
            .backupFailed(underlying),
            .temporaryWriteFailed(underlying),
            .replacementFailed(underlying),
            .annotatedCopyFailed(underlying),
        ]
        for error in errors {
            let message = try #require(error.errorDescription)
            #expect(message.contains("original") || message.contains("backup copy"))
            #expect(
                message.contains("move") || message.contains("check") || message.contains("close"),
                "the message must tell the user how to fix it, not just show the system error"
            )
        }
    }

    @Test("automatic saving is off by default and does not touch the file")
    func automaticWritingIsOffByDefault() async throws {
        let defaults = AppRuntime.defaults
        let oldValue = defaults.object(forKey: PDFWritePreference.defaultsKey)
        defaults.removeObject(forKey: PDFWritePreference.defaultsKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: PDFWritePreference.defaultsKey) }
            else { defaults.removeObject(forKey: PDFWritePreference.defaultsKey) }
        }
        #expect(!PDFWritePreference.isEnabled(defaults: defaults))

        let url = try StoreFixtures.makeTextPDF(fileName: "default-no-write.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try Data(contentsOf: url)
        let document = PDFFileDocument(data: original, displayName: url.lastPathComponent)
        let model = try #require(DocumentModel(document: document, fileURL: url))
        model.annotationController.load(fingerprint: "automatic-off-test", items: [])
        model.annotationController.create(Annotation(
            id: "a1", page: 0, kind: .note, color: AnnotationPaletteColor.yellow.color(),
            rect: AnnotationRect(x: 100, y: 100, width: 22, height: 22), text: "Non scrivere"
        ))
        #expect(model.automaticPDFSaveTask == nil)
        try await Task.sleep(for: .milliseconds(850))
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: PDFAnnotationWriteService.backupURL(for: url).path))
    }

    @Test("automatic saving writes only after explicit activation")
    func automaticWritingCanBeEnabled() async throws {
        let defaults = AppRuntime.defaults
        let oldValue = defaults.object(forKey: PDFWritePreference.defaultsKey)
        defaults.set(true, forKey: PDFWritePreference.defaultsKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: PDFWritePreference.defaultsKey) }
            else { defaults.removeObject(forKey: PDFWritePreference.defaultsKey) }
        }

        let url = try StoreFixtures.makeTextPDF(fileName: "automatic-on.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try Data(contentsOf: url)
        let model = try #require(DocumentModel(
            document: PDFFileDocument(data: original, displayName: url.lastPathComponent), fileURL: url
        ))
        model.annotationController.load(fingerprint: "automatic-on-test", items: [])
        model.annotationController.create(Annotation(
            id: "a1", page: 0, kind: .note, color: AnnotationPaletteColor.yellow.color(),
            rect: AnnotationRect(x: 100, y: 100, width: 22, height: 22), text: "Scrivi automaticamente"
        ))
        try await Task.sleep(for: .milliseconds(900))

        #expect(try Data(contentsOf: url) != original)
        #expect(FileManager.default.fileExists(atPath: PDFAnnotationWriteService.backupURL(for: url).path))
        let reopened = try #require(PDFDocument(url: url))
        let page = try #require(reopened.page(at: 0))
        #expect(page.annotations.contains {
            PDFAnnotationOwnership.tag(of: $0) == .init(role: .freeAnnotation, id: "a1")
        })
    }

    @Test("the new byte hash finds the same documento.json")
    func byteHashKeepsDocumentIdentity() async throws {
        let url = try StoreFixtures.makeTextPDF(fileName: "stessa-identita.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let dataFolder = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfF4EStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataFolder) }
        let fingerprint = try #require(StoreFixtures.fingerprint(ofPDFAt: url))
        let store = DocumentStore(dataFolderURL: dataFolder)
        let originalHash = try #require(DocumentStore.hashFileBytes(at: url))
        await store.registerDocument(
            fingerprint: fingerprint, byteHash: originalHash, fileName: url.lastPathComponent,
            lastKnownPath: url.path, title: "Stessa identità", pageCount: 1
        )
        await store.flush(fingerprint: fingerprint)

        let annotation = Annotation(
            id: "a1", page: 0, kind: .note, color: AnnotationPaletteColor.yellow.color(),
            rect: AnnotationRect(x: 120, y: 100, width: 22, height: 22), text: "Nota"
        )
        _ = try PDFAnnotationWriteService.write(
            originalURL: url, marks: [], freeAnnotations: [annotation], hue: .blu
        )
        await store.associateCurrentByteHash(fileURL: url, fingerprint: fingerprint)
        await store.flush(fingerprint: fingerprint)

        let newProcessStore = DocumentStore(dataFolderURL: dataFolder)
        let lookup = await newProcessStore.fastLookup(fileURL: url)
        #expect(lookup.fingerprint == fingerprint)
        #expect(lookup.record?.fingerprint == fingerprint)
    }

    @Test("an annotation written into the PDF is not duplicated when reopening the document with a second DocumentModel")
    func roundTripThroughDocumentModelHasNoDuplicateAnnotations() async throws {
        let url = try StoreFixtures.makeTextPDF(text: "Testo di prova per il round trip DocumentModel.", fileName: "round-trip-modello.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // First window: opens the new document and lets the real pipeline run
        // (needed because `applyStoreResult`, where the merge that avoids
        // duplicates lives, only starts from there or from the fast path; for
        // a PDF never seen before only the pipeline registers it).
        let firstData = try Data(contentsOf: url)
        let firstModel = try #require(DocumentModel(
            document: PDFFileDocument(data: firstData, displayName: url.lastPathComponent), fileURL: url
        ))
        PipelineRunner.run(model: firstModel)
        await waitUntil({ firstModel.storeFingerprint != nil })
        #expect(firstModel.storeFingerprint != nil)

        firstModel.annotationController.create(Annotation(
            id: "a1", page: 0, kind: .note, color: AnnotationPaletteColor.yellow.color(),
            rect: AnnotationRect(x: 100, y: 100, width: 22, height: 22), text: "Nota round trip"
        ))
        // Lets the annotation's asynchronous persistence finish before it is
        // read for writing into the PDF.
        try await Task.sleep(for: .milliseconds(250))
        firstModel.saveMarksIntoPDF()
        if case .failed(let message) = firstModel.pdfSaveState {
            Issue.record("write failed: \(message)")
        }
        firstModel.flushStore()
        try await Task.sleep(for: .milliseconds(300))

        let secondData = try Data(contentsOf: url)
        #expect(secondData != firstData)

        // Second window: same file, now with the annotation already written
        // into the PDF (signed by LelePdf) and already present in
        // `annotazioni.json`.
        let secondModel = try #require(DocumentModel(
            document: PDFFileDocument(data: secondData, displayName: url.lastPathComponent), fileURL: url
        ))
        PipelineRunner.run(model: secondModel)
        await waitUntil({ secondModel.storeFingerprint != nil })
        // `applyStoreResult` merges synchronously as soon as the fingerprint
        // arrives; a margin covers the possible async rewrite of the record
        // when the merge finds something different from what was saved.
        try await Task.sleep(for: .milliseconds(200))

        let matches = secondModel.annotationController.annotations.filter { $0.id == "a1" }
        #expect(matches.count == 1)
        #expect(matches.first?.externalPDFIdentifier == nil)
        #expect(matches.first?.text == "Nota round trip")
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func addPreviewHighlight(to url: URL) throws {
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 20, y: 145, width: 80, height: 16),
            forType: .highlight,
            withProperties: nil
        )
        annotation.color = .systemYellow
        annotation.userName = "Anteprima"
        annotation.setValue("preview-test-1", forAnnotationKey: .name)
        page.addAnnotation(annotation)
        let data = try #require(document.dataRepresentation())
        try data.write(to: url)
    }

    private func expectSameRGB(_ lhs: NSColor, _ rhs: NSColor) {
        let left = lhs.usingColorSpace(.deviceRGB) ?? lhs
        let right = rhs.usingColorSpace(.deviceRGB) ?? rhs
        #expect(abs(left.redComponent - right.redComponent) < 0.02)
        #expect(abs(left.greenComponent - right.greenComponent) < 0.02)
        #expect(abs(left.blueComponent - right.blueComponent) < 0.02)
    }

    private func subtype(of annotation: PDFAnnotation) -> PDFAnnotationSubtype? {
        guard let raw = annotation.type else { return nil }
        return PDFAnnotationSubtype(rawValue: raw.hasPrefix("/") ? raw : "/" + raw)
    }

    private func standardSubtypeForFreeAnnotation(_ kind: AnnotationKind) -> Set<PDFAnnotationSubtype> {
        switch kind {
        case .highlight: [.highlight]
        case .underline: [.underline]
        case .strikeout: [.strikeOut]
        case .ink, .star, .polygon: [.ink]
        case .rectangle, .roundedRectangle, .speechBubble: [.square]
        case .ellipse: [.circle]
        case .line, .arrow: [.line]
        case .textbox: [.freeText]
        case .note: [.text]
        }
    }
}

private extension MarkType {
    static let allCasesForTests: [MarkType] = [.rectangle, .circle, .underline, .arrow]
}
