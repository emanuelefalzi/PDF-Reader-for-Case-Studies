import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// `ChatOverlay` fills the entire window to anchor the button to the corner
/// (SPEC §5.9). In a real AppKit window the whole SwiftUI tree of a scene
/// (sidebar, dividers, `ChatOverlay`...) lives in ONE `NSHostingView`, which
/// claims `hitTest` for every point inside it so it can route the event to
/// its own internal dispatch. A test that calls `NSView.hitTest` directly on
/// `ChatOverlay` alone therefore proves nothing (it always returns itself,
/// whether the point is far from the button or not: the first version of
/// this file was wrong in just this way, and the note is kept for anyone
/// rereading it). The only real way to verify "the click reaches the divider
/// and is not trapped by ChatOverlay" is to inject a synthetic drag with
/// `NSEvent`/`NSWindow.sendEvent` on a composition that has BOTH together,
/// like `ThreePaneLayout` in production, and check that the state bound to
/// the divider actually changes.
// `.serialized`: real `NSWindow`/`NSHostingView`, same reason as
// `ChatOverlayCompositionTests`.
extension HeavyTestSuites {
@MainActor
@Suite("ChatOverlay does not block dragging the dividers", .serialized)
struct ChatOverlayHitTestingTests {
    private let windowSize = CGSize(width: 1200, height: 800)
    private let leftColumnWidth: CGFloat = 300

    private struct Harness: View {
        @Bindable var model: DocumentModel
        let leftColumnWidth: CGFloat

        var body: some View {
            // Same shape as `ThreePaneLayout`: a `ZStack` with the panes'
            // HStack below and `ChatOverlay()` on top, all in a single
            // SwiftUI tree (no separate `NSHostingView`).
            ZStack {
                HStack(spacing: 0) {
                    Color.gray.frame(width: leftColumnWidth)
                    PaneDivider(
                        width: $model.rightPanelWidth,
                        range: DSMetrics.rightPanelMinWidth...DSMetrics.rightPanelMaxWidth,
                        defaultWidth: DSMetrics.rightPanelDefaultWidth,
                        growsWithPositiveTranslation: false
                    )
                    Color.gray.frame(maxWidth: .infinity)
                }
                ChatOverlay()
            }
        }
    }

    @Test("dragging the divider changes the width even with ChatOverlay on top, with the chat closed")
    func dragThroughChatOverlayReachesDivider() throws {
        let model = try makeBareModel()
        let initialWidth = model.rightPanelWidth
        #expect(!model.chatController.isPresented, "the test must start with the chat closed, as in the reported bug")

        let (hostingView, window) = try makeWindow(model: model)
        defer { closeTestWindow(window) }

        // Center of the divider: right after the left column, in view
        // coordinates (origin at top left, like GeometryReader/SwiftUI; see
        // `ChatButtonLayout`).
        let dividerX = leftColumnWidth + DSMetrics.paneDividerWidth / 2
        let start = CGPoint(x: dividerX, y: windowSize.height / 2)
        // +60 pt to the right: for `PaneDivider(growsWithPositiveTranslation: false)`
        // (right pane) it must SHRINK.
        let dragged = CGPoint(x: dividerX + 60, y: windowSize.height / 2)

        sendMouse(.leftMouseDown, at: start, hostingView: hostingView, window: window, clickCount: 1)
        sendMouse(.leftMouseDragged, at: dragged, hostingView: hostingView, window: window, clickCount: 1)
        sendMouse(.leftMouseUp, at: dragged, hostingView: hostingView, window: window, clickCount: 1)

        #expect(model.rightPanelWidth != initialWidth, "dragging the divider did not change the width: ChatOverlay is still intercepting it")
        #expect(model.rightPanelWidth < initialWidth, "dragging the right divider to the right must shrink the pane, not widen it")
    }

    @Test("the chat button stays clickable on top of the same composition")
    func chatButtonStillOpensChat() throws {
        let model = try makeBareModel()
        #expect(!model.chatController.isPresented)

        let (hostingView, window) = try makeWindow(model: model)
        defer { closeTestWindow(window) }

        let buttonRect = ChatButtonLayout.frame(windowSize: windowSize)
        let center = CGPoint(x: buttonRect.midX, y: buttonRect.midY)

        sendMouse(.leftMouseDown, at: center, hostingView: hostingView, window: window, clickCount: 1)
        sendMouse(.leftMouseUp, at: center, hostingView: hostingView, window: window, clickCount: 1)

        #expect(model.chatController.isPresented, "the chat button no longer responds to a click in its corner")
    }

    // MARK: - Support

    private func makeWindow(model: DocumentModel) throws -> (NSHostingView<AnyView>, NSWindow) {
        // `.environment(model)`: `ChatOverlay` inside `Harness` reads
        // `@Environment(DocumentModel.self)`, as in production (see
        // `ChatOverlayCompositionTests`); without it SwiftUI crashes fatally
        // ("No Observable object of type DocumentModel found").
        let hostingView = NSHostingView(rootView: AnyView(
            Harness(model: model, leftColumnWidth: leftColumnWidth)
                .environment(model)
                .frame(width: windowSize.width, height: windowSize.height)
        ))
        hostingView.frame = CGRect(origin: .zero, size: windowSize)
        // Borderless: `contentView` occupies exactly the given rectangle, so
        // the coordinates computed above stay accurate.
        // Do NOT close it here: this window goes back to the caller, which
        // closes it at the end of the test (the two `@Test`s above already
        // have their own `defer`). Closing it here (an automatic insertion at
        // first, later removed) made it no longer key / no longer attached
        // BEFORE `sendMouse` simulated the click: `NSWindow.sendEvent` stopped
        // routing the event and the two tests above failed (found on the
        // first run after grouping into `HeavyTestSuites`).
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        // A key window is needed so `NSWindow.sendEvent` really routes the
        // synthetic event all the way to the SwiftUI gesture, as for a real
        // user click.
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        return (hostingView, window)
    }

    private func sendMouse(_ type: NSEvent.EventType, at pointInHostingBounds: CGPoint, hostingView: NSView, window: NSWindow, clickCount: Int) {
        let pointInWindow = hostingView.convert(pointInHostingBounds, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else {
            Issue.record("could not create the synthetic event \(type)")
            return
        }
        window.sendEvent(event)
    }

    private func makeBareModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(
            text: "Documento vuoto solo per l'ambiente di ChatOverlay.",
            fileName: "chat-overlay-hittest-\(UUID().uuidString).pdf"
        )
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "chat-overlay-hittest")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }
}
}
