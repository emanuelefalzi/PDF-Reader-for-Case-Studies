import AppKit
import Foundation
import UniformTypeIdentifiers

/// System panels for choosing a folder or an executable (SPEC §5.11, M10
/// "choose with NSOpenPanel" / "Choose..."). Isolated in one place
/// because both the data folder and the CLI path use them the same way.
@MainActor
enum SettingsPanels {
    static func chooseFolder(startingAt url: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let url { panel.directoryURL = url }
        return panel.runModal() == .OK ? panel.urls.first : nil
    }

    static func chooseExecutable() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        return panel.runModal() == .OK ? panel.urls.first : nil
    }

    /// A single file with the given extension (`.docx`, but it does not
    /// enforce a `UTType`: a user might have a template with another
    /// extension that Word recognizes). Used for the Word template for export
    /// ("Choose...").
    static func chooseFile(startingAt url: URL?, allowedExtension: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // `chooseFolder`/`chooseExecutable` above also use "Choose" now: same
        // prompt everywhere.
        panel.prompt = "Choose"
        panel.allowedContentTypes = UTType(filenameExtension: allowedExtension).map { [$0] } ?? []
        if let url { panel.directoryURL = url }
        return panel.runModal() == .OK ? panel.urls.first : nil
    }
}
