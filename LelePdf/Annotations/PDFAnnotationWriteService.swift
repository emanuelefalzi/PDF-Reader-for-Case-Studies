import Foundation
@preconcurrency import PDFKit

enum PDFAnnotationWriteError: Error, LocalizedError {
    case originalReadFailed(Error)
    case missingDocument
    case cannotSerialize
    case sourceTextChanged
    case coordinationFailed(Error)
    case backupFailed(Error)
    case temporaryWriteFailed(Error)
    case replacementFailed(Error)
    case annotatedCopyFailed(Error)

    var errorDescription: String? {
        switch self {
        case .originalReadFailed(let error):
            String(localized: "Can't read the original PDF (\(error.localizedDescription)). Check that the file still exists and reopen it.")
        case .missingDocument:
            String(localized: "Can't read the original PDF. Check that the file still exists and reopen it.")
        case .cannotSerialize:
            String(localized: "Can't prepare the annotated PDF. The original was not modified; try reopening it.")
        case .sourceTextChanged:
            String(localized: "The PDF on disk changed after it was opened. For safety it was not modified: close it and reopen it before saving.")
        case .coordinationFailed(let error):
            String(localized: "macOS did not allow the save to be prepared (\(error.localizedDescription)). Close the other apps using the PDF and try again.")
        case .backupFailed(let error):
            String(localized: "Can't create the backup copy next to the PDF (\(error.localizedDescription)). The original is intact: move the PDF to a folder you can write to and try again.")
        case .temporaryWriteFailed(let error):
            String(localized: "Can't create the temporary file in the PDF's folder (\(error.localizedDescription)). The original is intact: check the folder permissions and free space.")
        case .replacementFailed(let error):
            String(localized: "Can't replace the PDF with the annotated version (\(error.localizedDescription)). The original and the backup copy are intact: close the other apps using the file and try again.")
        case .annotatedCopyFailed(let error):
            String(localized: "PDFKit would change this document's internal text, so it is not safe to replace the original. Could not create an annotated copy either (\(error.localizedDescription)): move the PDF to a folder you can write to and try again.")
        }
    }
}

/// Writes annotations into the original file with a one-time backup and
/// atomic replacement. If PDFKit's reserialization alters the text, it
/// instead keeps the original byte-for-byte and creates an atomic annotated
/// copy. All PDFKit work stays on the MainActor; temporaries live in the
/// destination folder, so `replaceItemAt` does not cross volumes and does
/// not expose partial PDFs.
@MainActor
enum PDFAnnotationWriteService {
    struct Result: Sendable, Equatable {
        var backupURL: URL
        var backupCreated: Bool
        var annotationCount: Int
        var destinationURL: URL
        var wroteOriginal: Bool
    }

    static func backupURL(for originalURL: URL) -> URL {
        originalURL.deletingLastPathComponent().appendingPathComponent(
            originalURL.deletingPathExtension().lastPathComponent + ".lelepdf-backup.pdf"
        )
    }

    static func annotatedCopyURL(for originalURL: URL) -> URL {
        originalURL.deletingLastPathComponent().appendingPathComponent(
            originalURL.deletingPathExtension().lastPathComponent + ".lelepdf-annotato.pdf"
        )
    }

    static func write(
        originalURL: URL,
        marks: [PDFMarkSnapshot],
        freeAnnotations: [Annotation],
        hue: MaterialHue,
        expectedFingerprint: String? = nil,
        textIntegrityCheck: (PDFDocument, PDFDocument) -> Bool = {
            DocumentFingerprint.compute(for: $0) == DocumentFingerprint.compute(for: $1)
        },
        beforeReplace: () throws -> Void = {}
    ) throws -> Result {
        let accessedSecurityScope = originalURL.startAccessingSecurityScopedResource()
        defer { if accessedSecurityScope { originalURL.stopAccessingSecurityScopedResource() } }

        var coordinatedResult: Result?
        var operationError: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        // This is a content update of the same document, not a "Save As":
        // NSFileCoordinator.h prescribes empty options even though the
        // implementation uses a temporary + atomic rename.
        coordinator.coordinate(writingItemAt: originalURL, options: [], error: &coordinationError) { coordinatedURL in
            do {
                coordinatedResult = try writeCoordinated(
                    originalURL: coordinatedURL, marks: marks,
                    freeAnnotations: freeAnnotations, hue: hue,
                    expectedFingerprint: expectedFingerprint,
                    textIntegrityCheck: textIntegrityCheck,
                    beforeReplace: beforeReplace
                )
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw PDFAnnotationWriteError.coordinationFailed(coordinationError) }
        guard let coordinatedResult else {
            throw PDFAnnotationWriteError.coordinationFailed(CocoaError(.fileWriteUnknown))
        }
        return coordinatedResult
    }

    private static func writeCoordinated(
        originalURL: URL,
        marks: [PDFMarkSnapshot],
        freeAnnotations: [Annotation],
        hue: MaterialHue,
        expectedFingerprint: String?,
        textIntegrityCheck: (PDFDocument, PDFDocument) -> Bool,
        beforeReplace: () throws -> Void
    ) throws -> Result {
        let fileManager = FileManager.default
        let originalData: Data
        do {
            originalData = try Data(contentsOf: originalURL)
        } catch {
            throw PDFAnnotationWriteError.originalReadFailed(error)
        }
        guard let document = PDFDocument(data: originalData) else { throw PDFAnnotationWriteError.missingDocument }
        let originalFingerprint = DocumentFingerprint.compute(for: document)
        if let expectedFingerprint, expectedFingerprint != originalFingerprint {
            throw PDFAnnotationWriteError.sourceTextChanged
        }

        // Idempotence: we replace all and only our own annotations; native
        // Preview annotations already in the file stay.
        PDFAnnotationOwnership.removeOwnedAnnotations(from: document)
        var count = 0
        for mark in marks {
            guard let page = document.page(at: mark.page),
                  let annotation = PDFMarkAnnotationBuilder.make(mark, hue: hue) else { continue }
            page.addAnnotation(annotation)
            count += 1
        }
        for model in freeAnnotations where model.externalPDFIdentifier == nil {
            guard let page = document.page(at: model.page) else { continue }
            let annotation = AnnotationBuilder.makePersistablePDFAnnotation(for: model)
            PDFAnnotationOwnership.tag(annotation, role: .freeAnnotation, id: model.id)
            page.addAnnotation(annotation)
            count += 1
        }

        guard let outputData = document.dataRepresentation() else { throw PDFAnnotationWriteError.cannotSerialize }
        guard let verificationDocument = PDFDocument(data: outputData) else { throw PDFAnnotationWriteError.cannotSerialize }

        // Some complex PDFs (reproduced on the real Draghi report) get
        // rewritten by PDFKit with an altered font Unicode map: the PDF stays
        // visually similar, but copy/search and our fingerprint change. We do
        // not weaken the guard. In that case the original is never opened
        // for writing: we atomically save an explicitly recognizable
        // annotated copy.
        if !textIntegrityCheck(document, verificationDocument) {
            let copyURL = annotatedCopyURL(for: originalURL)
            do {
                try writeAtomically(outputData, to: copyURL, fileManager: fileManager)
            } catch {
                throw PDFAnnotationWriteError.annotatedCopyFailed(error)
            }
            return Result(
                backupURL: backupURL(for: originalURL), backupCreated: false,
                annotationCount: count, destinationURL: copyURL,
                wroteOriginal: false
            )
        }

        let backupURL = backupURL(for: originalURL)
        let backupCreated: Bool
        do {
            backupCreated = try createBackupIfNeeded(originalData, at: backupURL, fileManager: fileManager)
        } catch {
            throw PDFAnnotationWriteError.backupFailed(error)
        }
        let temporaryURL = originalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(originalURL.lastPathComponent).lelepdf-\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        do {
            try outputData.write(to: temporaryURL, options: .withoutOverwriting)
            try copyPermissions(from: originalURL, to: temporaryURL, fileManager: fileManager)
        } catch {
            throw PDFAnnotationWriteError.temporaryWriteFailed(error)
        }
        guard let temporaryDocument = PDFDocument(url: temporaryURL),
              DocumentFingerprint.compute(for: temporaryDocument) == originalFingerprint else {
            throw PDFAnnotationWriteError.cannotSerialize
        }

        // Test injection point: if an interruption arrives here, the
        // original file was never opened for writing.
        try beforeReplace()
        do {
            _ = try fileManager.replaceItemAt(originalURL, withItemAt: temporaryURL)
        } catch {
            throw PDFAnnotationWriteError.replacementFailed(error)
        }
        return Result(
            backupURL: backupURL, backupCreated: backupCreated,
            annotationCount: count, destinationURL: originalURL,
            wroteOriginal: true
        )
    }

    private static func writeAtomically(_ data: Data, to destinationURL: URL, fileManager: FileManager) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    private static func createBackupIfNeeded(
        _ data: Data, at backupURL: URL, fileManager: FileManager
    ) throws -> Bool {
        guard !fileManager.fileExists(atPath: backupURL.path) else { return false }
        let temporaryBackup = backupURL.deletingLastPathComponent().appendingPathComponent(
            ".\(backupURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryBackup) }
        try data.write(to: temporaryBackup, options: .withoutOverwriting)
        do {
            try fileManager.moveItem(at: temporaryBackup, to: backupURL)
            return true
        } catch CocoaError.fileWriteFileExists {
            return false
        }
    }

    private static func copyPermissions(
        from originalURL: URL, to temporaryURL: URL, fileManager: FileManager
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: originalURL.path)
        if let permissions = attributes[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)
        }
    }
}
