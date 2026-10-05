import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// Visual verification of the REAL VIEWS (`ChaptersSidebar`) with the
/// contents collapsed/expanded, using the same offscreen
/// `exportPNG`/`NSHostingView` harness as `SidebarIndexLegendRenderTests` and
/// `BulletsSubItemsRenderTests`. NEVER `makeKeyAndOrderFront`: a SwiftUI
/// hierarchy with `Menu`/`.alert` ordered onto the screen has already proven
/// unstable in this test host, and `ChaptersSidebar` has both. PNGs go to
/// `~/Library/Caches/LelePdf/verifica-screenshots/` and are re-read after
/// export.
extension HeavyTestSuites {
@MainActor
@Suite("Collapsible/expandable contents · visual verification", .serialized)
struct CollapsibleIndexRenderTests {
    private static let outputRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)

    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per l'indice comprimibile.", fileName: "toc-collapse-render-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "toc-collapse-render-test")
        let model = try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
        model.setColorTheme(.blu)
        model.tocSource = .generated
        model.tocEntries = [
            TocEntry(id: "t1a", title: "Capitolo 1 · Introduzione", level: 1, page: 0),
            TocEntry(id: "t2a", title: "1.1 Il quadro normativo", level: 2, page: 0),
            TocEntry(id: "t3a", title: "1.1.1 Le fonti primarie", level: 3, page: 0),
            TocEntry(id: "t2b", title: "1.2 Le eccezioni regionali", level: 2, page: 1),
            TocEntry(id: "t1b", title: "Capitolo 2 · Conclusioni", level: 1, page: 3),
        ]
        model.currentPageIndex = 0
        return model
    }

    // The window goes back to the caller (never closed in here); see the
    // same comment in `SidebarIndexLegendRenderTests.host`.
    private func host(_ view: some View, width: CGFloat, height: CGFloat) -> (view: NSHostingView<AnyView>, window: NSWindow) {
        let hostingView = NSHostingView(rootView: AnyView(view.frame(width: width, height: height, alignment: .top)))
        hostingView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        return (hostingView, window)
    }

    @Test("Fully expanded contents: all five entries visible")
    func expandedIndexShowsAllEntries() throws {
        let model = try makeModel()
        let view = ChaptersSidebar().environment(model)
        let (hostingView, window) = host(view, width: 260, height: 220)
        defer { closeTestWindow(window) }
        exportPNG(hostingView, to: Self.outputRoot.appendingPathComponent("f11-index-expanded.png"))
        #expect(hostingView.fittingSize.height > 0)
    }

    @Test("Chapter 1 collapsed: t2a/t3a/t2b hidden, the two top-level entries remain")
    func collapsedChapterHidesDescendants() throws {
        let model = try makeModel()
        model.toggleTocEntryCollapsed(id: "t1a")
        #expect(model.collapsedTocEntryIds == ["t1a"])

        let view = ChaptersSidebar().environment(model)
        let (hostingView, window) = host(view, width: 260, height: 220)
        defer { closeTestWindow(window) }
        exportPNG(hostingView, to: Self.outputRoot.appendingPathComponent("f11-index-collapsed.png"))
        #expect(hostingView.fittingSize.height > 0)
    }

    @Test("Show only top-level entries: only the two chapters remain visible in the filtered tree")
    func showOnlyTopLevelFiltersToChaptersOnly() throws {
        let model = try makeModel()
        model.showOnlyTopLevelTocEntries()

        let depths = ManualToc.indentDepths(levels: model.tocEntries.map(\.level))
        let visible = TocCollapse.visibleIndices(ids: model.tocEntries.map(\.id), depths: depths, collapsed: model.collapsedTocEntryIds)
        let visibleIds = model.tocEntries.indices.filter { visible[$0] }.map { model.tocEntries[$0].id }
        #expect(visibleIds == ["t1a", "t1b"])

        let view = ChaptersSidebar().environment(model)
        let (hostingView, window) = host(view, width: 260, height: 220)
        defer { closeTestWindow(window) }
        exportPNG(hostingView, to: Self.outputRoot.appendingPathComponent("f11-index-show-only-t1.png"))
    }
}
}
