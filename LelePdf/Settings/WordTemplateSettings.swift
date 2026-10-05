import Foundation

/// "Word template for export": "Choose..." copies the `.docx` picked by
/// the user ONLY ONCE into the app's folder in Application Support
/// (unpacked into individual files, not the whole archive).
/// `RewriteDocxTemplateStore` then reads those files directly, without
/// ever reopening the original zip or asking for Desktop access again on
/// every export. "Restore default template" deletes that folder: from
/// then on `RewriteDocxTemplateStore.resolve` falls back to the built-in
/// template (`RewriteDocxDefaultTemplate`).
///
/// Isolation in tests (same principle as `AppRuntime`/
/// `DocumentStore.resolveDataFolder`): under XCTest the user's real
/// Application Support folder is NEVER touched; a folder dedicated to the
/// test process is used, or `LELEPDF_WORD_TEMPLATE_DIR` if set (for
/// scripts), exactly like `LELEPDF_DATA_DIR`.
@MainActor
enum WordTemplateSettings {
    /// `UserDefaults`: `true` if the user has chosen a template (told apart
    /// from "never chosen" by the absence of the key, not a `false` default;
    /// same principle as `SidebarPreferences`/`object(forKey:)`).
    static let hasCustomTemplateDefaultsKey = "wordTemplateCustomChosen"
    /// `true` if the user has explicitly chosen to stay on the built-in
    /// template (from the first export's sheet, or from "Restore" in
    /// Settings), as distinct from "has not chosen anything yet", in the same
    /// way as `hasCustomTemplateDefaultsKey`.
    static let builtInTemplateChosenDefaultsKey = "wordTemplateBuiltInChosen"
    /// "Emphasise marked terms" option, off by default: absence of the key =
    /// `false`, same principle as the other preferences here.
    static let emphasizeMarkedTermsDefaultsKey = "wordTemplateEmphasizeMarkedTerms"

    enum ImportError: Error {
        case cannotReadFile
        case notAZipArchive
        case emptyArchive
    }

    static func hasCustomTemplate() -> Bool {
        AppRuntime.defaults.bool(forKey: hasCustomTemplateDefaultsKey)
    }

    /// `true` if the user has made ANY choice (their own template, or
    /// explicitly "use the built-in template"). It governs whether the first
    /// Word export must still ask (`RewriteExportController`).
    static func hasMadeTemplateChoice() -> Bool {
        hasCustomTemplate() || AppRuntime.defaults.bool(forKey: builtInTemplateChosenDefaultsKey)
    }

    /// "Use the built-in template" in the first export's sheet: it does not
    /// touch `hasCustomTemplateDefaultsKey` (it stays the built-in template),
    /// it only records that the choice has been made.
    static func chooseBuiltInTemplateExplicitly() {
        AppRuntime.defaults.set(true, forKey: builtInTemplateChosenDefaultsKey)
    }

    /// Label for the Export menu/the right panel ("the Export menu shows which
    /// template will be used"): pure, taking two booleans instead of re-reading
    /// `AppRuntime.defaults` itself, so a SwiftUI view can pass its own
    /// `@AppStorage` values (it updates right after "Choose..."/"Restore",
    /// same principle as `SettingsView`).
    static func templateMenuLabel(hasCustomTemplate: Bool, builtInTemplateChosenExplicitly: Bool) -> String {
        if hasCustomTemplate { return "Custom template" }
        if builtInTemplateChosenExplicitly { return "Built-in template" }
        return "No template chosen"
    }

    static func templateMenuLabel() -> String {
        templateMenuLabel(hasCustomTemplate: hasCustomTemplate(), builtInTemplateChosenExplicitly: AppRuntime.defaults.bool(forKey: builtInTemplateChosenDefaultsKey))
    }

    /// "Emphasise marked terms": off by default, a single option for all
    /// three export formats (`RewriteExportController`).
    static func emphasizeMarkedTerms() -> Bool {
        AppRuntime.defaults.bool(forKey: emphasizeMarkedTermsDefaultsKey)
    }

    /// Folder where the chosen template's files live (or would live, if
    /// nothing was ever chosen). ALWAYS the same for a given process, never
    /// read/written if `hasCustomTemplate()` is false.
    static func storageDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["LELEPDF_WORD_TEMPLATE_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if AppRuntime.isRunningUnderXCTest {
            return AppRuntime.xctestDataFolderURL.appendingPathComponent("word-template", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LelePdf/word-template", isDirectory: true)
    }

    /// Folder to pass to `RewriteDocxTemplateStore.resolve`: `nil` if the
    /// user never chose anything (built-in template), otherwise
    /// `storageDirectory()`. `RewriteDocxTemplateStore` tells apart on its
    /// own "folder missing/empty" (a chosen template that became unreadable,
    /// reported) from "no folder passed" (the normal built-in template).
    static func activeTemplateDirectory() -> URL? {
        hasCustomTemplate() ? storageDirectory() : nil
    }

    /// "Choose...": reads `sourceURL` (the user's `.docx`, for example
    /// "styles template .docx"), unpacks it (`MinimalZipReader`) and writes
    /// each entry into `storageDirectory()`, replacing what was there before.
    /// It NEVER modifies or copies `sourceURL` itself elsewhere.
    static func chooseTemplate(at sourceURL: URL) throws {
        guard let archiveData = try? Data(contentsOf: sourceURL) else { throw ImportError.cannotReadFile }
        let entries: [String: Data]
        do {
            entries = try MinimalZipReader.readEntries(from: archiveData)
        } catch {
            throw ImportError.notAZipArchive
        }
        guard !entries.isEmpty else { throw ImportError.emptyArchive }

        let directory = storageDirectory()
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in entries {
            let fileURL = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        }
        AppRuntime.defaults.set(true, forKey: hasCustomTemplateDefaultsKey)
        // Choosing ONE template (one's own) still counts as "having made a
        // choice": there is no need to ask again on the next export.
        AppRuntime.defaults.set(true, forKey: builtInTemplateChosenDefaultsKey)
    }

    /// "Restore default template". This too is an explicit choice (the user
    /// has just decided to stay on the built-in template), so it no longer
    /// asks on the next Word export.
    static func restoreDefaultTemplate() {
        try? FileManager.default.removeItem(at: storageDirectory())
        AppRuntime.defaults.set(false, forKey: hasCustomTemplateDefaultsKey)
        AppRuntime.defaults.set(true, forKey: builtInTemplateChosenDefaultsKey)
    }
}
