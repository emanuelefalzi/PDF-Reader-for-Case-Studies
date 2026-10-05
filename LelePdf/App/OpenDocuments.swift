import AppKit
import Observation
import SwiftUI

/// Registry of the open document windows (SPEC §6.3 "multiple windows"),
/// added in M10 for the Summary Lab (SPEC §5.14): that window lives in a
/// separate `Scene` (Window menu/Settings), not inside the
/// `DocumentWindowView` tree, so `@FocusedValue(\.documentModel)`
/// (`DocumentCommands.swift`) is no longer enough: it stops reflecting a
/// document as soon as the Lab window itself takes focus. Instead it keeps
/// "the last document window that became key", updated both on open and
/// on every key-window change (`WindowKeyObserver`, below).
@MainActor
@Observable
final class OpenDocuments {
    static let shared = OpenDocuments()

    private(set) var active: DocumentModel?
    @ObservationIgnored private var all: [ObjectIdentifier: DocumentModel] = [:]

    func register(_ model: DocumentModel) {
        all[ObjectIdentifier(model)] = model
        active = model
    }

    func unregister(_ model: DocumentModel) {
        all[ObjectIdentifier(model)] = nil
        if active === model { active = all.values.first }
    }

    func markActive(_ model: DocumentModel) {
        guard all[ObjectIdentifier(model)] != nil else { return }
        active = model
    }
}

/// Invisible bridge to the document window's `NSWindow` (no visible view,
/// `frame(width: 0, height: 0)`): observes `didBecomeKeyNotification` only
/// on THIS window so as not to confuse two documents open together. The
/// same kind of AppKit bridge already used elsewhere in the app
/// (`PDFKitView`, `MarkedNSTextView`).
struct WindowKeyObserver: NSViewRepresentable {
    // `@MainActor @Sendable`: the closure passed by `DocumentWindowView`
    // captures a `DocumentModel` (not `Sendable`, MainActor); isolating it to
    // `@MainActor` still makes it safe to send, since every call goes through
    // a hop to that actor, unlike a plain `@Sendable`, which the compiler
    // would reject (Swift 6 "sending risks causing data races").
    let onBecomeKey: @MainActor @Sendable () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.observe(window: window, onBecomeKey: onBecomeKey)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var token: NSObjectProtocol?

        func observe(window: NSWindow, onBecomeKey: @escaping @MainActor @Sendable () -> Void) {
            guard token == nil else { return }
            if window.isKeyWindow { onBecomeKey() }
            // Not removed in a `deinit` (nonisolated by construction in Swift 6, it
            // could not safely touch `token`): filtered by `object: window`, it
            // stops having any effect on its own when the window is deallocated, a
            // negligible cost (one small block never invoked again) for a view that
            // lives as long as the document window itself.
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { _ in
                Task { @MainActor in onBecomeKey() }
            }
        }
    }
}
