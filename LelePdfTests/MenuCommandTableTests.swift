import SwiftUI
import Testing
@testable import LelePdf

/// Reported bug: "the basic shortcuts of any Mac application... do not work".
/// The quality bar asks for a verifiable command table, not just a manual
/// pass through the real app (not possible from an automated session). This
/// suite checks `MenuCommandTable` (`App/MenuCommandTable.swift`), the
/// declarative map of every command/shortcut of the app.
@Suite("Menu command table")
struct MenuCommandTableTests {
    @Test("every required menu has at least one command")
    func everyRequiredMenuHasCommands() {
        let byMenu = Dictionary(grouping: MenuCommandTable.all) { $0.menu }
        for menu in MenuCommandSpec.Menu.allCases {
            #expect(byMenu[menu]?.isEmpty == false, "menu \(menu.rawValue) has no command in the table")
        }
    }

    @Test("no duplicate shortcuts: two commands do not share the same key combination")
    func noDuplicateShortcuts() {
        let conflicts = MenuCommandTable.conflicts()
        let description = conflicts.map { key, specs in
            "\(key.key)+\(key.modifiers) → \(specs.map(\.title).joined(separator: ", "))"
        }.joined(separator: "; ")
        #expect(conflicts.isEmpty, "duplicate shortcuts found: \(description)")
    }

    @Test("the explicitly required commands are all in the table, with the right shortcut")
    func requiredCommandsPresentWithExpectedShortcut() {
        // File
        expectShortcut(id: "file.open", key: "o", modifiers: .command)
        expectShortcut(id: "file.close", key: "w", modifiers: .command)
        // Edit
        expectShortcut(id: "edit.undo", key: "z", modifiers: .command)
        expectShortcut(id: "edit.redo", key: "z", modifiers: [.command, .shift])
        expectShortcut(id: "edit.copy", key: "c", modifiers: .command)
        expectShortcut(id: "edit.selectAll", key: "a", modifiers: .command)
        expectShortcut(id: "edit.find", key: "f", modifiers: .command)
        expectShortcut(id: "edit.findNext", key: "g", modifiers: .command)
        expectShortcut(id: "edit.findPrevious", key: "g", modifiers: [.command, .shift])
        // View
        expectShortcut(id: "view.zoomIn", key: "+", modifiers: .command)
        expectShortcut(id: "view.zoomOut", key: "-", modifiers: .command)
        expectShortcut(id: "view.zoomActualSize", key: "0", modifiers: .command)
        // Go
        expectShortcut(id: "go.previousPage", key: "[", modifiers: .command)
        expectShortcut(id: "go.nextPage", key: "]", modifiers: .command)
        // Window
        expectShortcut(id: "window.enterFullScreen", key: "f", modifiers: [.command, .control])
        expectShortcut(id: "window.minimize", key: "m", modifiers: .command)
        // Settings
        expectShortcut(id: "app.settings", key: ",", modifiers: .command)
        // Analysis
        expectShortcut(id: "analysis.analyzeNext", key: "\r", modifiers: .command)
    }

    @Test("every command declared by one of our own Commands (not systemProvided) appears in the table with the same id/shortcut; see DocumentCommands/AnalysisCommands/NavigationCommands")
    func customCommandsMatchDeclaredShortcuts() {
        // Mirror of `DocumentCommands`/`AnalysisCommands`/`NavigationCommands`:
        // if a shortcut changes in one file but not in the other, this test
        // fails instead of the mismatch being discovered by hand in the app.
        let expected: [(id: String, key: Character, modifiers: EventModifiers)] = [
            ("file.savePDFMarks", "s", .command),
            ("file.close", "w", .command),
            ("edit.find", "f", .command),
            ("edit.findNext", "g", .command),
            ("edit.findPrevious", "g", [.command, .shift]),
            ("view.toggleChat", "j", .command),
            ("view.closeTransientOverlays", "\u{1B}", []),
            ("view.toggleSidebar", "1", [.command, .shift]),
            ("view.toggleRightPanel", "2", [.command, .shift]),
            ("view.toggleFollowPDF", "l", [.command, .option]),
            ("view.toggleLegend", "g", [.command, .option]),
            ("view.toggleAnnotationToolbar", "a", [.command, .shift]),
            ("contents.headingT1", "1", [.command, .option]),
            ("contents.headingT2", "2", [.command, .option]),
            ("contents.headingT3", "3", [.command, .option]),
            ("contents.headingT4", "4", [.command, .option]),
            ("view.zoomIn", "+", .command),
            ("view.zoomOut", "-", .command),
            ("view.zoomActualSize", "0", .command),
            ("go.previousPage", "[", .command),
            ("go.nextPage", "]", .command),
            ("analysis.analyzeNext", "\r", .command),
            ("window.enterFullScreen", "f", [.command, .control]),
        ]
        for entry in expected {
            expectShortcut(id: entry.id, key: entry.key, modifiers: entry.modifiers)
            let spec = MenuCommandTable.all.first { $0.id == entry.id }
            #expect(spec?.systemProvided == false, "\(entry.id) is declared by one of our own Commands: it must not be marked systemProvided")
        }
    }

    @Test("system commands (Open/Undo/Redo/Copy/Select All/Minimize/Settings) are marked systemProvided, not duplicated by one of our own Commands")
    func systemProvidedCommandsAreMarked() {
        // "Close" and "Enter Full Screen" are NOT in this list: verified with
        // the real `NSApp.mainMenu` (`RealMenuBarTests.swift`) that they do not
        // come for free from AppKit/SwiftUI in this app, so they are now
        // declared by `WindowStateCommands`.
        let systemIds = ["file.open", "file.openRecent", "edit.undo", "edit.redo", "edit.copy", "edit.selectAll", "window.minimize", "window.zoom", "app.settings"]
        for id in systemIds {
            let spec = MenuCommandTable.all.first { $0.id == id }
            #expect(spec?.systemProvided == true, "\(id) should be marked systemProvided (it comes for free from AppKit/SwiftUI)")
        }
    }

    private func expectShortcut(id: String, key: Character, modifiers: EventModifiers) {
        guard let spec = MenuCommandTable.all.first(where: { $0.id == id }) else {
            Issue.record("command \"\(id)\" missing from the table")
            return
        }
        #expect(spec.key == key, "command \"\(id)\": expected key \(key), found \(String(describing: spec.key))")
        #expect(spec.modifiers == modifiers, "command \"\(id)\": expected modifiers \(modifiers), found \(spec.modifiers)")
    }
}
