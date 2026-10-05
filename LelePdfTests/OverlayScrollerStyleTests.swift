import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// The PDF's vertical scroll bar must appear only while scrolling or when the
/// mouse moves near the right edge ("overlay style"), even when macOS would
/// show scroll bars permanently because a mouse is connected. Instead of
/// relying on the system preference, `PDFKitView`/`RewriteScrollHost` force
/// `scrollerStyle = .overlay` on the real `NSScrollView`. Same real window
/// approach as `RewriteScrollHostTests` (per the M6 test-host crash note: no
/// real AppKit windows across parallel suites).
extension HeavyTestSuites {
@MainActor
@Suite("Reader/RewritePanel: overlay scroll bar style", .serialized)
struct OverlayScrollerStyleTests {
    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeMultiPageTextPDF(pageCount: 3, fileName: "overlay-scroller-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "overlay-scroller-test")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }

    @Test("PDF: the real NSScrollView is forced to the overlay style, not the system one")
    func pdfScrollViewUsesOverlayStyle() throws {
        let model = try makeModel()
        let pdfView = PDFKitView(model: model)
        let hostingView = NSHostingView(rootView: pdfView)
        hostingView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)

        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        let scrollView = try #require(model.readerBridge?.enclosingScrollView)
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.autohidesScrollers == true)
    }

    @Test("Right panel: same overlay style choice as the PDF")
    func rewritePanelScrollViewUsesOverlayStyleToo() throws {
        let model = try makeModel()
        let host = RewriteScrollHost(model: model) {
            Text("Riga di prova").frame(height: 60)
        }
        let hostingView = NSHostingView(rootView: host)
        hostingView.frame = CGRect(x: 0, y: 0, width: 392, height: 600)

        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        let scrollView = try #require(model.rewriteScrollView)
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.autohidesScrollers == true)
    }
}
}
