import Foundation
@preconcurrency import PDFKit

/// Converts a range of a block's clean text into `PDFSelection`s (SPEC §7.3
/// last point): it stays on the MainActor because `PDFDocument`/
/// `PDFSelection` are not `Sendable`. A mark straddling two pages produces
/// two selections, one per page.
@MainActor
enum BlockSelectionResolver {
    static func selections(for cleanRange: NSRange, in block: TextBlock, document: PDFDocument) -> [PDFSelection] {
        block.resolve(cleanRange: cleanRange).compactMap { pageIndex, range in
            guard let page = document.page(at: pageIndex) else { return nil }
            return page.selection(for: range)
        }
    }
}
