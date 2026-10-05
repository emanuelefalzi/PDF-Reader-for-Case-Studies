import AppKit
import Foundation
import Testing
@testable import LelePdf

/// Minimal M8→M6 integration. The suite touches AppKit and `DocumentModel`,
/// so it stays on the MainActor and serialized like the other real
/// scroll-view tests (lessons from the test host crashes in M6).
@MainActor
@Suite("MapNavigation", .serialized)
struct MapNavigationTests {
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    @Test("clicking a node scrolls the card even with Follow the PDF off")
    func nodeClickScrollsRewritePanelDirectly() throws {
        let sourceURL = try StoreFixtures.makeTextPDF(
            text: "Documento di prova per la navigazione dalla mappa.",
            fileName: "map-navigation-\(UUID().uuidString).pdf"
        )
        let document = PDFFileDocument(data: try Data(contentsOf: sourceURL), displayName: "map-navigation")
        let model = try #require(DocumentModel(document: document))
        model.followPDF = false

        let panel = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 150))
        panel.documentView = FlippedDocumentView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        panel.contentView.setFrameSize(NSSize(width: 300, height: 150))
        model.syncCoordinator.attachPanel(scrollView: panel, model: model)
        model.syncCoordinator.segments = [
            AlignmentSegment(id: "b-target", pdfStart: 0, pdfHeight: 100, panelStart: 240, panelHeight: 100),
        ]

        let node = MapNode(
            id: "term", label: "Termine", shape: .rectangle, weight: 1,
            firstOccurrence: MapOccurrence(
                blockId: "target", markId: "mark", page: 0,
                range: MarkRange(start: 0, length: 7)
            ),
            chapterIDs: ["document"], primaryChapterID: "document"
        )
        model.navigateToMapNode(node)

        // panelStart 240 − reading line (150 × 30%) = 195.
        #expect(DocumentSpace.visibleTopDown(panel)?.top == 195)
        model.syncCoordinator.detach()
    }
}
