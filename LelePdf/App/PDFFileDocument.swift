import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import PDFKit

/// PDF document opened in viewing mode by `DocumentGroup`.
///
/// SwiftUI's automatic channel stays read-only and
/// `fileWrapper(configuration:)` always returns the bytes as opened. The
/// only write allowed goes through the explicit command and
/// `PDFAnnotationWriteService`, which applies a backup and an atomic replace.
struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [] }

    /// Original PDF bytes, unchanged from open to close.
    let data: Data

    /// File name shown in the view (without extension).
    let displayName: String

    init(configuration: ReadConfiguration) throws {
        guard let fileData = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = fileData
        displayName = configuration.file.filename ?? "Document"
    }

    /// For previews/in-memory tests only: not used by the normal open flow.
    init(data: Data, displayName: String) {
        self.data = data
        self.displayName = displayName
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Read-only: always returns the original bytes unchanged.
        // Saving into the PDF does not go through DocumentGroup: this channel
        // stays a faithful pass-through, so closing a window never writes.
        makeUnchangedFileWrapper()
    }

    /// Pass-through logic isolated from SwiftUI's opaque types
    /// (`FileDocumentWriteConfiguration`), so it is directly testable:
    /// see `PDFFileDocumentTests`.
    func makeUnchangedFileWrapper() -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
