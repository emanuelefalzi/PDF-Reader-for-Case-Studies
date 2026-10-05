import Foundation
@preconcurrency import PDFKit

/// Page thumbnails for the Pages sidebar (SPEC §5.3), generated lazily and
/// cached. `PDFPage.thumbnail(of:for:)` must be called on the MainActor: no
/// background work, but each thumbnail is requested only when its row enters
/// the `LazyVStack` (so the "small batch" is the window of visible rows plus
/// the lazy stack's margin, not a manual loop over all the pages).
@MainActor
final class ThumbnailCache {
    private let cache = NSCache<NSNumber, NSImage>()
    private let document: PDFDocument
    let thumbnailSize: NSSize

    /// Built eagerly by `DocumentModel.init` (not lazily behind a view
    /// `@State`): the size is derived here from the first page rather than in
    /// `ThumbnailsSidebar`, so the cache already exists (stable for the whole
    /// life of the window) by the time the first `LazyVStack` row runs its
    /// `.task`. It used to be built in the view's `onAppear`, populating an
    /// optional `@State`: rows already visible at the first layout started
    /// with `cache == nil`, and their `.task(id: index)` was not re-run when
    /// the cache arrived (the id does not change), so they stayed blank
    /// forever.
    init(document: PDFDocument, thumbnailWidth: CGFloat = DSMetrics.thumbnailWidth) {
        self.document = document
        let ratio = Self.aspectRatio(of: document)
        self.thumbnailSize = NSSize(width: thumbnailWidth, height: thumbnailWidth * ratio)
        cache.countLimit = 400
    }

    private static func aspectRatio(of document: PDFDocument) -> CGFloat {
        guard let bounds = document.page(at: 0)?.bounds(for: .mediaBox), bounds.width > 0 else {
            return 1.3
        }
        return bounds.height / bounds.width
    }

    func cached(at index: Int) -> NSImage? {
        cache.object(forKey: NSNumber(value: index))
    }

    /// Returns the thumbnail, generating it if it is not cached yet.
    /// `Task.yield()` before the heavy work lets the interface breathe when
    /// several rows request one in the same frame.
    func thumbnail(at index: Int) async -> NSImage? {
        if let cached = cached(at: index) { return cached }
        await Task.yield()
        guard let page = document.page(at: index) else { return nil }
        let image = PerfProbe.measure("thumb.generate") { page.thumbnail(of: thumbnailSize, for: .mediaBox) }
        cache.setObject(image, forKey: NSNumber(value: index))
        return image
    }
}
