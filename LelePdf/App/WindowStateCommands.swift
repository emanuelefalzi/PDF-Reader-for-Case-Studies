import SwiftUI
import AppKit

/// REAL cause of "system shortcuts don't work, not even ⌃⌘F": not an
/// interceptor of ours. All of `App/`/`Reader/`/`Annotations/` was
/// re-read: the local wheel monitor (`PDFReaderCoordinator+
/// WheelZoom.swift`) is registered ONLY for `[.scrollWheel, .magnify]`,
/// never for `.keyDown` (verified again by reading the registration
/// line, not on hearsay), and no other view overrides
/// `performKeyEquivalent(with:)` (which, for a shortcut with modifiers
/// such as ⌃⌘F, is evaluated by the application menu BEFORE reaching the
/// first responder anyway). An earlier investigation had therefore
/// correctly ruled out an interceptor, but stopped there, without ever
/// checking whether the command STILL EXISTED in the real menu.
///
/// Verified with the REAL `NSApp.mainMenu`, inside the test app's process
/// (the test target is "app-hosted": `TEST_HOST` points to `LelePdf.app`,
/// so the real app has already been launched and its menu bar built when
/// a test runs; no UI driving is needed to read it, just
/// `NSApplication.shared.mainMenu`, see
/// `LelePdfTests/RealMenuBarTests.swift`): with a real document open
/// (`.resizable` window, `collectionBehavior` with `.fullScreenPrimary`
/// confirmed), **"Close" and "Full Screen" appear nowhere in the
/// real menu**, neither before nor after opening the document. SwiftUI's
/// `CommandGroupPlacement` table (macOS 26 SDK, `SwiftUI.swiftinterface`)
/// does not even have a `.closeItem` case, and nothing corresponds to
/// "Full Screen": both are historically an automatic addition by
/// AppKit to the menu bar of an app built from a static `MainMenu.xib`,
/// never guaranteed for a menu bar built dynamically by SwiftUI for a
/// `DocumentGroup(viewing:)` that at launch, with no file passed, first
/// shows the Open panel (no full-screen window is possible at that
/// moment). Both had been marked `systemProvided: true` in
/// `MenuCommandTable` without ever being compared with the real menu: it
/// was the wrong question ("who intercepts the event" instead of "does
/// the command really exist").
///
/// Fixed here by declaring them explicitly, as already done for
/// Find/Zoom/Go in `DocumentCommands`/`NavigationCommands`: it no longer
/// relies on an undocumented AppKit behavior that, as it turned out, is
/// not reliable in this app. `NSApp.keyWindow` (not
/// `model`/`FocusedValue`): exactly the same window the automatic AppKit
/// menu item would have acted on, had it existed.
struct WindowStateCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(fullScreenTitle) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            .disabled(model == nil)
        }

        CommandGroup(after: .newItem) {
            Button("Close") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model == nil)
        }
    }

    /// "Full Screen"/"Exit Full Screen", as AppKit would do on its own:
    /// no `NSMenuItem` is needed, SwiftUI recreates the label on every menu
    /// update (same pattern as a `Button` with a title computed elsewhere in
    /// the app, e.g. `PDFSaveCommands`).
    private var fullScreenTitle: String {
        NSApp.keyWindow?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Full Screen"
    }
}
