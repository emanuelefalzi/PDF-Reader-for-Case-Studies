import SwiftUI

@main
struct LelePdfApp: App {
    init() {
        // M10 (SPEC §13 "CLI version/flags check at launch"): before this
        // milestone Claude's status was checked only when a right panel
        // appeared (`RewritePanel.task`, M4), never if the app stops at the
        // `DocumentGroup` Open panel with no recent documents. A check here
        // runs once per process, as soon as the app starts, regardless of when
        // (or whether) a document window appears.
        Task { @MainActor in await ClaudeStatusModel.shared.refresh() }
    }

    var body: some Scene {
        DocumentGroup(viewing: PDFFileDocument.self) { configuration in
            DocumentWindowView(document: configuration.document, fileURL: configuration.fileURL)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            PDFSaveCommands()
            DocumentCommands()
            NavigationCommands()
            AnalysisCommands()
            ContentsCommands()
            ExportCommands()
            DebugCommands()
            // "Close"/"Full Screen" declared explicitly: they do not come
            // for free from AppKit in this app, see `WindowStateCommands.swift`.
            WindowStateCommands()
        }

        Settings {
            SettingsView()
        }

        // SPEC §5.14 "Summary Lab": a separate window, from the Window menu
        // (added for free by SwiftUI for every `Window` scene) or from a button
        // in Settings.
        Window("Summary Lab", id: LaboratorioView.windowID) {
            LaboratorioView()
        }
        .defaultSize(width: 920, height: 640)
    }
}
