import Foundation

/// "Save marks into the PDF" command and its optional automatic save.
/// The preference is read at the time of the mutation, so changing it in
/// Settings applies immediately even to windows that are already open.
@MainActor
extension DocumentModel {
    var canWriteOriginalPDF: Bool { fileURL != nil }

    func saveMarksIntoPDF() {
        automaticPDFSaveTask?.cancel()
        automaticPDFSaveTask = nil
        performPDFSave()
    }

    func scheduleAutomaticPDFSaveIfEnabled() {
        guard PDFWritePreference.isEnabled(), fileURL != nil else { return }
        automaticPDFSaveTask?.cancel()
        automaticPDFSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            self.performPDFSave()
        }
    }

    func performPDFSave() {
        guard pdfSaveState != .saving, let fileURL else { return }
        let marks = pdfMarkSnapshots()
        let freeAnnotations = annotationController.annotations
        guard !marks.isEmpty || freeAnnotations.contains(where: { $0.externalPDFIdentifier == nil }) else {
            pdfSaveState = .saved(String(localized: "No marks to save"))
            return
        }

        pdfSaveState = .saving
        do {
            let result = try PDFAnnotationWriteService.write(
                originalURL: fileURL,
                marks: marks,
                freeAnnotations: freeAnnotations,
                hue: colorTheme,
                expectedFingerprint: storeFingerprint ?? DocumentFingerprint.compute(for: pdfDocument)
            )
            if result.wroteOriginal {
                pdfSaveState = .saved(String(localized: "\(result.annotationCount) marks saved in the PDF"))
            } else {
                pdfSaveState = .saved(
                    String(localized: "The original was not modified: PDFKit would change its internal text. Saved an annotated copy in \(result.destinationURL.lastPathComponent) instead.")
                )
            }
            if result.wroteOriginal, let storeFingerprint {
                Task {
                    await AppStore.shared.associateCurrentByteHash(fileURL: fileURL, fingerprint: storeFingerprint)
                    await AppStore.shared.flush(fingerprint: storeFingerprint)
                }
            }
        } catch {
            pdfSaveState = .failed(error.localizedDescription)
        }
    }

    /// Only real marks (`markId != nil`) are written. The 40% repetitions are
    /// a derived visual aid, not data chosen by the user/Claude, and must not
    /// fill the PDF with permanent annotations.
    private func pdfMarkSnapshots() -> [PDFMarkSnapshot] {
        guard let context = analysisController.context else { return [] }
        var result: [PDFMarkSnapshot] = []
        for pageIndex in 0 ..< pageCount {
            for item in analysisController.markItems(forPage: pageIndex, document: pdfDocument) {
                guard let blockID = item.blockId, let markID = item.markId,
                      let mark = context.analysis.blocks[blockID]?.marks.first(where: { $0.id == markID }) else { continue }
                result.append(PDFMarkSnapshot(
                    id: "\(blockID):\(markID):p\(pageIndex)",
                    page: pageIndex,
                    type: item.type,
                    text: mark.text,
                    lineRects: item.lineRects.map(AnnotationRect.init)
                ))
            }
        }
        return result
    }
}
