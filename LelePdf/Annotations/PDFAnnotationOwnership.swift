import Foundation
@preconcurrency import PDFKit

/// Persistent signature of the annotations LelePdf writes into the PDF.
///
/// `/NM` is the standard unique name of a PDF annotation; `T`/`userName`
/// stays "LelePdf", also readable by Preview. The private keys are
/// redundant on purpose: they help future versions of the app, while the
/// standard fields are enough to recognize the annotation if another editor
/// discards private extensions.
@MainActor
enum PDFAnnotationOwnership {
    enum Role: String, Sendable {
        case mark
        case freeAnnotation = "annotation"
    }

    struct Tag: Sendable, Equatable {
        var role: Role?
        var id: String?
    }

    private static let owner = "LelePdf"
    private static let namePrefix = "lelepdf:"
    private static let ownerKey = PDFAnnotationKey(rawValue: "LelePdfOwner")
    private static let roleKey = PDFAnnotationKey(rawValue: "LelePdfRole")
    private static let idKey = PDFAnnotationKey(rawValue: "LelePdfId")

    static func tag(_ annotation: PDFAnnotation, role: Role, id: String) {
        annotation.userName = owner
        annotation.modificationDate = Date()
        annotation.setValue(namePrefix + role.rawValue + ":" + id, forAnnotationKey: .name)
        annotation.setValue(owner, forAnnotationKey: ownerKey)
        annotation.setValue(role.rawValue, forAnnotationKey: roleKey)
        annotation.setValue(id, forAnnotationKey: idKey)
    }

    static func tag(of annotation: PDFAnnotation) -> Tag? {
        let privateOwner = annotation.value(forAnnotationKey: ownerKey) as? String
        let standardOwner = annotation.userName
        guard privateOwner == owner || standardOwner == owner else { return nil }

        let privateRole = (annotation.value(forAnnotationKey: roleKey) as? String).flatMap(Role.init(rawValue:))
        let privateID = annotation.value(forAnnotationKey: idKey) as? String
        if privateRole != nil || privateID != nil {
            return Tag(role: privateRole, id: privateID)
        }

        guard let name = annotation.value(forAnnotationKey: .name) as? String,
              name.hasPrefix(namePrefix) else {
            // Even if an editor stripped `/NM` and the private keys, `T`
            // still identifies the annotation as ours: it must not be
            // imported as a free Preview annotation.
            return Tag(role: nil, id: nil)
        }
        let payload = name.dropFirst(namePrefix.count)
        guard let separator = payload.firstIndex(of: ":") else { return Tag(role: nil, id: nil) }
        let role = Role(rawValue: String(payload[..<separator]))
        let id = String(payload[payload.index(after: separator)...])
        return Tag(role: role, id: id.isEmpty ? nil : id)
    }

    /// Removes from the in-memory document all copies already written by
    /// LelePdf. Preview's annotations stay untouched.
    static func removeOwnedAnnotations(from document: PDFDocument) {
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where tag(of: annotation) != nil {
                page.removeAnnotation(annotation)
            }
        }
    }
}
