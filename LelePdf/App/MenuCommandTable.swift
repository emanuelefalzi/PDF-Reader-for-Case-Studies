import SwiftUI

/// Menu command table (quality criteria: "every command visible in a menu",
/// "no system shortcut intercepted by the app"): the single source of
/// truth for which commands the app declares, with which shortcut and in
/// which menu, testable without launching a real `NSApplication`/`NSMenu`
/// (`LelePdfTests/MenuCommandTableTests.swift`).
///
/// Every entry with a REAL shortcut declared by one of our `Commands`
/// (`DocumentCommands`/`AnalysisCommands`/`NavigationCommands`) has a row
/// here with the SAME key combination. The uniqueness test below is there
/// to catch a future double shortcut early (two different commands with
/// the same key+modifiers "steal" the event from each other, a common
/// cause of shortcuts that suddenly "don't work").
///
/// `systemProvided == true` marks the commands that come for free from
/// AppKit/`DocumentGroup`/`Settings` (Open, Close, Undo, Copy, Select
/// All, Settings, Full Screen, Minimize, Window Zoom): not declared by a
/// `Commands` of ours, listed here for completeness ("every command
/// visible in a menu" applies to these too) and to include them in the
/// uniqueness check: a shortcut of ours must never repeat that of a
/// system command.
struct MenuCommandSpec: Identifiable, Equatable, Sendable {
    enum Menu: String, Sendable, CaseIterable, Equatable {
        case app = "LelePdf"
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case go = "Go"
        case window = "Window"
        case analysis = "Analysis"
        /// Menu dedicated to the contents commands (⌘⌥1…4, "Expand All", "Show
        /// Only T1"). SPEC suggests "a Contents or Edit menu"; a `CommandMenu` of
        /// its own, like "Analysis", keeps these commands findable without
        /// crowding Edit/View.
        case contents = "Contents"
    }

    let id: String
    let menu: Menu
    let title: String
    /// Shortcut character (`KeyEquivalent` is a simple wrapper around a
    /// `Character`, the same values used by `.escape`/`.return`; see the
    /// comments on the individual entries below). `nil` for a command with no
    /// keyboard shortcut (e.g. "Regenerate Contents", "Export").
    let key: Character?
    let modifiers: EventModifiers
    let systemProvided: Bool

    init(id: String, menu: Menu, title: String, key: Character?, modifiers: EventModifiers = [], systemProvided: Bool = false) {
        self.id = id
        self.menu = menu
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.systemProvided = systemProvided
    }

    /// Conflict key: two commands that BOTH have a shortcut "steal" the event
    /// from each other if they have the same character and EXACTLY THE SAME
    /// modifiers (a different subset is a different combination for AppKit,
    /// e.g. ⌘F and ⇧⌘F do not conflict). `modifiersRawValue` instead of
    /// `EventModifiers` directly: `OptionSet` does not guarantee `Hashable`,
    /// its `RawValue` (`Int`) does.
    struct ConflictKey: Hashable {
        let key: Character
        let modifiersRawValue: Int

        var modifiers: EventModifiers { EventModifiers(rawValue: modifiersRawValue) }
    }

    var conflictKey: ConflictKey? {
        guard let key else { return nil }
        return ConflictKey(key: key, modifiersRawValue: modifiers.rawValue)
    }
}

/// Quality criteria: File (Open ⌘O, Close ⌘W), Edit (⌘Z/⇧⌘Z/⌘C/⌘A/⌘F), Go
/// (previous/next page), Window (Full Screen ⌃⌘F, Minimize ⌘M, Zoom),
/// View (PDF zoom ⌘+/⌘-/⌘0, show/hide sidebar, show/hide rewrite),
/// Settings ⌘,, plus ⌘↩ "Analyze the Next Block" (SPEC §5.5).
enum MenuCommandTable {
    static let all: [MenuCommandSpec] = [
        // MARK: File — SPEC §5.2 "Open (⌘O) ... File › Open Recent", M0 "no save command"
        .init(id: "file.open", menu: .file, title: "Open…", key: "o", modifiers: .command, systemProvided: true),
        .init(id: "file.openRecent", menu: .file, title: "Open Recent", key: nil, systemProvided: true),
        // NOT systemProvided: bug "system shortcuts don't work, not even ⌃⌘F".
        // Verified with the REAL `NSApp.mainMenu` inside the test app's process
        // (`LelePdfTests/RealMenuBarTests.swift`) that "Close" does not appear
        // at all in the real menu built by `DocumentGroup(viewing:)`, neither
        // before nor after opening a document; SwiftUI's
        // `CommandGroupPlacement` (macOS 26 SDK) does not even have a
        // `.closeItem` case. Now declared explicitly by `WindowStateCommands`.
        .init(id: "file.close", menu: .file, title: "Close", key: "w", modifiers: .command),
        // `PDFSaveCommands`: found missing from this table during the review
        // pass; it replaces the generic system `.saveItem` (hence NOT
        // `systemProvided`, it is a command of ours even though on the same ⌘S
        // combination) and without a row here the shortcut uniqueness test did
        // not check it at all.
        .init(id: "file.savePDFMarks", menu: .file, title: "Save the Marks in the PDF", key: "s", modifiers: .command),
        // SPEC §5.1 point 8 "File (... Export)", §8: two scopes x three formats,
        // no shortcut (`ExportCommands`).
        .init(id: "file.export.copy.whole", menu: .file, title: "Export › Whole Document › Copy with Formatting", key: nil),
        .init(id: "file.export.pdf.whole", menu: .file, title: "Export › Whole Document › PDF…", key: nil),
        .init(id: "file.export.docx.whole", menu: .file, title: "Export › Whole Document › Word (.docx)…", key: nil),
        .init(id: "file.export.copy.section", menu: .file, title: "Export › Current Section › Copy with Formatting", key: nil),
        .init(id: "file.export.pdf.section", menu: .file, title: "Export › Current Section › PDF…", key: nil),
        .init(id: "file.export.docx.section", menu: .file, title: "Export › Current Section › Word (.docx)…", key: nil),

        // MARK: Edit — SPEC §5.1/§5.7/§5.13; ⌘F is the only one not free (DocumentCommands)
        .init(id: "edit.undo", menu: .edit, title: "Undo", key: "z", modifiers: .command, systemProvided: true),
        .init(id: "edit.redo", menu: .edit, title: "Redo", key: "z", modifiers: [.command, .shift], systemProvided: true),
        .init(id: "edit.copy", menu: .edit, title: "Copy", key: "c", modifiers: .command, systemProvided: true),
        .init(id: "edit.selectAll", menu: .edit, title: "Select All", key: "a", modifiers: .command, systemProvided: true),
        .init(id: "edit.find", menu: .edit, title: "Find", key: "f", modifiers: .command),
        // SPEC §5.10 "↩/⌘G next, ⇧↩/⇧⌘G previous": ⏎/⇧⏎ stay local to the
        // search field (not a real menu shortcut), ⌘G/⇧⌘G are real commands
        // because they must work "with focus anywhere".
        .init(id: "edit.findNext", menu: .edit, title: "Find Next", key: "g", modifiers: .command),
        .init(id: "edit.findPrevious", menu: .edit, title: "Find Previous", key: "g", modifiers: [.command, .shift]),

        // MARK: View — SPEC §5.1 "⌘+/⌘− zoom", panels (M1)
        .init(id: "view.zoomIn", menu: .view, title: "Zoom In", key: "+", modifiers: .command),
        .init(id: "view.zoomOut", menu: .view, title: "Zoom Out", key: "-", modifiers: .command),
        .init(id: "view.zoomActualSize", menu: .view, title: "Actual Size", key: "0", modifiers: .command),
        // ⌘⌥1/⌘⌥2 replaced ⌃⌘S/⌥⌘I (explicit request from the user): same
        // action, a single shortcut. Later moved to ⌘⇧1/⌘⇧2 to free ⌘⌥1…4 for
        // the T1-T4 headings.
        .init(id: "view.toggleSidebar", menu: .view, title: "Sidebar", key: "1", modifiers: [.command, .shift]),
        .init(id: "view.toggleRightPanel", menu: .view, title: "Right Panel (Rewrite)", key: "2", modifiers: [.command, .shift]),
        .init(id: "view.toggleFollowPDF", menu: .view, title: "Follow the PDF", key: "l", modifiers: [.command, .option]),
        .init(id: "view.toggleLegend", menu: .view, title: "Legend", key: "g", modifiers: [.command, .option]),
        .init(id: "view.toggleAnnotationToolbar", menu: .view, title: "Annotation Toolbar", key: "a", modifiers: [.command, .shift]),
        .init(id: "view.toggleChat", menu: .view, title: "Ask the PDF", key: "j", modifiers: .command),
        .init(id: "view.closeTransientOverlays", menu: .view, title: "Close Chat and Map", key: "\u{1B}" /* .escape */, modifiers: []),

        // MARK: Go — SPEC does not fix a shortcut; the "square brackets" convention already used for back/forward in many Mac apps was chosen.
        .init(id: "go.previousPage", menu: .go, title: "Previous Page", key: "[", modifiers: .command),
        .init(id: "go.nextPage", menu: .go, title: "Next Page", key: "]", modifiers: .command),

        // MARK: Window — Minimize/Zoom are automatic (AppKit/SwiftUI); Full
        // Screen is NOT (see the note on "file.close" above, same real cause):
        // declared explicitly by `WindowStateCommands`.
        .init(id: "window.enterFullScreen", menu: .window, title: "Full Screen", key: "f", modifiers: [.command, .control]),
        .init(id: "window.minimize", menu: .window, title: "Minimize", key: "m", modifiers: .command, systemProvided: true),
        .init(id: "window.zoom", menu: .window, title: "Zoom", key: nil, systemProvided: true),

        // MARK: Settings — automatic (`Settings` scene)
        .init(id: "app.settings", menu: .app, title: "Settings…", key: ",", modifiers: .command, systemProvided: true),

        // MARK: Analysis — SPEC §5.5 "⌘↩ analyze the next block"
        .init(id: "analysis.analyzeNext", menu: .analysis, title: "Analyze the Next Block", key: "\r" /* .return */, modifiers: .command),

        // MARK: Contents — ⌘⌥1…4, freed up by moving the sidebar/right panel
        // toggles to ⌘⇧1/⌘⇧2 (above). On the current selection in the PDF
        // (single or multiple with ⌘) they create/change the level of a T1-T4
        // entry.
        .init(id: "contents.headingT1", menu: .contents, title: "Set as T1", key: "1", modifiers: [.command, .option]),
        .init(id: "contents.headingT2", menu: .contents, title: "Set as T2", key: "2", modifiers: [.command, .option]),
        .init(id: "contents.headingT3", menu: .contents, title: "Set as T3", key: "3", modifiers: [.command, .option]),
        .init(id: "contents.headingT4", menu: .contents, title: "Set as T4", key: "4", modifiers: [.command, .option]),
        // "Show Only T1"/"Expand All": no shortcut specified, only
        // menu entries (also in the "..." menu of the Contents tab,
        // `ChaptersSidebar`, for those who never open the Contents menu).
        .init(id: "contents.showOnlyT1", menu: .contents, title: "Show Only T1", key: nil),
        .init(id: "contents.expandAll", menu: .contents, title: "Expand All", key: nil),
    ]

    /// Entries with a real shortcut, grouped by key combination (SPEC
    /// §2.1/§2.2 "no system shortcut intercepted": two commands with the same
    /// combination steal it from each other).
    static func conflicts() -> [MenuCommandSpec.ConflictKey: [MenuCommandSpec]] {
        Dictionary(grouping: all.filter { $0.conflictKey != nil }) { $0.conflictKey! }
            .filter { $0.value.count > 1 }
    }
}
