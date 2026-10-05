import Foundation

/// An entry of the contents (native or generated), used by the Chapters
/// sidebar, by search with the "Chapter" scope and later by the Store (SPEC
/// §8: `toc.entries[{id,title,level,page}]`).
///
/// `page` is the 0-based page index (`PDFDocument.index(for:)`), like
/// `DocumentModel.currentPageIndex`; the UI adds 1 to show it.
struct TocEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// 1-3 for a native/generated entry (SPEC §7.4); 1-4 for a manual T1-T4
    /// entry (v2.3 §5.3, §8).
    let level: Int
    let page: Int
    /// `nil`/`.auto` for native or generated entries; `.manual` for those
    /// added or changed by hand (v2.3 §5.3, M7).
    var origin: TocEntryOrigin? = nil
    /// Vertical position of the selection in page space (v2.3 §8 `pageY`):
    /// `nil` for native/generated entries, which do not need it (there are
    /// never two on the same page that require a finer ordering).
    var pageY: Double? = nil

    var isManual: Bool { origin == .manual }
}

/// Where the contents shown in the Chapters sidebar come from (SPEC §5.3).
enum TocSource: Sendable {
    /// No useful contents and not yet generated (arrives in M4).
    case none
    case native
    case generated
}

/// State of the contents generation (SPEC §7.4, §5.3, M4): drives the
/// empty/loading/error state of the contents tab (`ChaptersSidebar`).
enum TocGenerationState: Sendable, Equatable {
    case idle
    case generating
    case failed(String)
}
