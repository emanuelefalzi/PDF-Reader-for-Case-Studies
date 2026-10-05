import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LelePdf

/// `ChatInlineText`: the `AttributedString` of a paragraph must keep the
/// chip text with no spaces added around it (otherwise the punctuation after
/// the chip detaches, the same defect reported by the user, only shifted one
/// level) and the placeholder link must route back to the right page.
@MainActor
@Suite("ChatInlineText")
struct ChatInlineTextTests {
    @Test("plain text stays unchanged, the chip only loses its square brackets")
    func plainConcatenationHasNoExtraSpacing() {
        let segments: [ChatSegment] = [
            .text("scarso successo commerciale"),
            .citation(label: "[p. 2]", page: 2),
            .text(". Nello stesso periodo"),
        ]
        let attributed = ChatInlineText.attributedString(for: segments)
        #expect(String(attributed.characters) == "scarso successo commercialep. 2. Nello stesso periodo")
    }

    @Test("the chip link leads to the correct page and is the only one recognized")
    func citationLinkRoundTrips() throws {
        let url = try #require(URL(string: "\(ChatInlineText.citationScheme):12"))
        #expect(ChatInlineText.citationPage(from: url) == 12)
        #expect(ChatInlineText.citationPage(from: URL(string: "https://example.com")!) == nil)
    }

    @Test("an external block (<fuori>) produces no text in the flow's AttributedString")
    func externalSegmentsAreSkipped() {
        let attributed = ChatInlineText.attributedString(for: [.external("ignorato qui")])
        #expect(String(attributed.characters).isEmpty)
    }

    @Test("renders a sample answer to PNG for visual verification")
    func renderSampleAnswerForVisualCheck() throws {
        let segments: [ChatSegment] = [
            .text("Il documento descrive l'azienda, con scarso successo commerciale "),
            .citation(label: "[p. 2]", page: 2),
            .text(". Nello stesso periodo il mercato cresceva rapidamente, secondo l'analisi presentata."),
        ]
        let attributed = ChatInlineText.attributedString(for: segments)
        let view = Text(attributed)
            .font(.system(size: 13))
            .frame(width: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("PNG rendering failed")
            return
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("chat-citazioni-in-linea.png")
        try png.write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
