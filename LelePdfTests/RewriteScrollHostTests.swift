import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// Regression (SPEC §5.8, M6): the first measurement run crashed the
/// verification app 13 times in a row (uncaught Objective-C exception)
/// because `RewriteScrollHost.makeNSView` activated a constraint between
/// `container` (the future `documentView`) and `scrollView.contentView`
/// *before* assigning `scrollView.documentView = container`: the two views
/// did not yet share a common ancestor.
/// Fixed by reversing the order; this test instantiates the host inside a
/// real window and forces a layout pass, so a regression of the same kind
/// would crash the suite instead of passing unnoticed.
// `.serialized` like `ScrollSyncCoordinatorTests`/`ScrollSyncReentrancyTests`:
// this suite also creates a real `NSWindow` for layout, and it is safer not
// to let Swift Testing interleave the creation/destruction of real AppKit
// windows across different suites running in parallel (the M6 test-host
// crash).
extension HeavyTestSuites {
@MainActor
@Suite("Sync: RewriteScrollHost (layout regression)", .serialized)
struct RewriteScrollHostTests {
    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova per il pannello.", fileName: "scrollhost-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "scrollhost-test")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }

    @Test("the documentView is attached before the constraints to the clip view are activated: no Auto Layout exception during layout")
    func makeNSViewDoesNotThrowDuringLayout() throws {
        let model = try makeModel()
        let host = RewriteScrollHost(model: model) {
            Text("Riga di prova").frame(height: 60)
        }
        let hostingView = NSHostingView(rootView: host)
        hostingView.frame = CGRect(x: 0, y: 0, width: 392, height: 600)

        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        // Torn down at the end of the test with `closeTestWindow` (`orderOut`
        // + `contentView = nil`, NEVER `.close()`), no longer left to ARC
        // alone as this note originally said: `.close()` is what caused the
        // double release in `ScrollSyncReentrancyTests`, not the pair used
        // here. `false` stays anyway to remove any doubt, consistent with
        // that other test.
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        // If this line is reached, `makeNSView` did not throw the exception:
        // the host wired the `NSScrollView` to the model.
        #expect(model.rewriteScrollView != nil)
    }
}
}
