import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// `ChatButtonLayoutTests` verifies the formula (SPEC §5.9); this test
/// mounts the real view to check that the SwiftUI composition actually
/// honors it. A wrong composition was precisely the cause of the bug
/// (`ChatOverlay` without `.frame(maxWidth: .infinity, maxHeight:
/// .infinity)`, so the parent `ZStack` of `ThreePaneLayout`, with its default
/// `.center` alignment, centered the button in the window instead of
/// anchoring it to the corner). A test on the formula alone would not have
/// caught it.
// `.serialized`: real `NSWindow`/`NSHostingView`, same reason as
// `RewritePanelRealContentLayoutTests`.
extension HeavyTestSuites {
@MainActor
@Suite("ChatOverlay · composition", .serialized)
struct ChatOverlayCompositionTests {
    @Test("given a proposed window size, the view fills it instead of shrinking to the button")
    func expandsToFillProposedSize() throws {
        let model = try makeBareModel()
        // `NSHostingController.sizeThatFits(in:)` (macOS 13+, unlike
        // `NSHostingView.fittingSize`, which measures the ideal size with NO
        // proposal at all and therefore collapses to the content anyway)
        // answers a concrete proposal, as the parent `ZStack` of
        // `ThreePaneLayout` would with the real window size.
        // Before the fix (`ChatOverlay` without `.frame(maxWidth:
        // .infinity, maxHeight: .infinity)`) the view stayed at ~76×76 pt
        // (button + margins) here too, and the parent `ZStack`, with its
        // default `.center` alignment, centered it in the window instead of
        // anchoring it to the corner.
        let controller = NSHostingController(rootView: ChatOverlay().environment(model))
        let proposed = CGSize(width: 1200, height: 800)
        let fitted = controller.sizeThatFits(in: proposed)
        #expect(fitted.width > 1000, "ChatOverlay still shrinks to just the button (\(fitted.width) pt wide on a proposal of \(proposed.width) pt): the centered-button bug would come back")
        #expect(fitted.height > 700, "ChatOverlay still shrinks to just the button (\(fitted.height) pt tall on a proposal of \(proposed.height) pt): the centered-button bug would come back")
    }

    /// Also exports a PNG for visual inspection (same principle as
    /// `MapRenderExportTests`): more reliable than reading individual pixels
    /// programmatically, which depends on coordinate conventions and backing
    /// store scale that are not guaranteed in an offscreen test host.
    @Test("inside a real window the button appears in the corner, exported for visual inspection")
    func rendersAtCorner() throws {
        let model = try makeBareModel()
        let windowSize = CGSize(width: 1200, height: 800)
        let hostingView = NSHostingView(rootView:
            ChatOverlay().environment(model).frame(width: windowSize.width, height: windowSize.height)
                .background(Color.white)
        )
        hostingView.frame = CGRect(origin: .zero, size: windowSize)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        // Temporary capture bitmap, released immediately (see `exportPNG` in
        // CardItemOverlapTests.swift, same reason).
        try autoreleasepool {
            guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                Issue.record("could not capture the bitmap for the test")
                return
            }
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                Issue.record("could not encode the PNG")
                return
            }
            let outputRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            try png.write(to: outputRoot.appendingPathComponent("chat-button-corner.png"))
        }
    }

    private func makeBareModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(
            text: "Documento vuoto solo per l'ambiente di ChatOverlay.",
            fileName: "chat-overlay-\(UUID().uuidString).pdf"
        )
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "chat-overlay-test")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }
}
}
