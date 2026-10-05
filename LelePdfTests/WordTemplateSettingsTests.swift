import Foundation
import Testing
@testable import LelePdf

/// F7 ("Choose…"/"Restore default template"): `WordTemplateSettings`
/// writes/deletes ONLY inside `AppRuntime.xctestDataFolderURL` during tests
/// (never the user's real Application Support), same principle as
/// `DocumentStore.resolveDataFolder`.
@Suite("WordTemplateSettings: choose/restore the template")
@MainActor
struct WordTemplateSettingsTests {
    private func makeSyntheticDocx() -> Data {
        MinimalZipWriter.makeArchive(entries: [
            .init(path: "word/document.xml", data: Data("<w:document/>".utf8)),
            .init(path: "word/styles.xml", data: Data("<w:styles><w:style w:styleId=\"Normal\"/></w:styles>".utf8)),
            .init(path: "word/numbering.xml", data: Data("<w:numbering/>".utf8)),
        ])
    }

    @Test("Choose…: unpacks the .docx into Application Support (test), sets the flag; Restore: removes it")
    func chooseThenRestore() throws {
        // Cleanup (another suite in this same process may have already chosen a template).
        WordTemplateSettings.restoreDefaultTemplate()
        #expect(!WordTemplateSettings.hasCustomTemplate())
        #expect(WordTemplateSettings.activeTemplateDirectory() == nil)

        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfWordTemplateSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let sourceFile = sourceDir.appendingPathComponent("modello.docx")
        try makeSyntheticDocx().write(to: sourceFile)

        try WordTemplateSettings.chooseTemplate(at: sourceFile)
        #expect(WordTemplateSettings.hasCustomTemplate())
        let activeDir = try #require(WordTemplateSettings.activeTemplateDirectory())
        #expect(FileManager.default.fileExists(atPath: activeDir.appendingPathComponent("word/styles.xml").path))

        let resolved = RewriteDocxTemplateStore.resolve(customTemplateDirectory: activeDir)
        #expect(!resolved.customTemplateUnreadable)
        #expect(resolved.availableStyleIds.contains("Normal"))

        WordTemplateSettings.restoreDefaultTemplate()
        #expect(!WordTemplateSettings.hasCustomTemplate())
        #expect(!FileManager.default.fileExists(atPath: activeDir.path))
    }

    @Test("no choice made -> hasMadeTemplateChoice false; explicit 'Use the built-in template' -> true, without becoming a custom template")
    func explicitBuiltInChoiceCountsAsMade() {
        WordTemplateSettings.restoreDefaultTemplate()
        // `restoreDefaultTemplate` is itself an explicit choice: the flag is
        // also reset to isolate the "never chosen" case.
        AppRuntime.defaults.removeObject(forKey: WordTemplateSettings.hasCustomTemplateDefaultsKey)
        AppRuntime.defaults.removeObject(forKey: WordTemplateSettings.builtInTemplateChosenDefaultsKey)
        #expect(!WordTemplateSettings.hasMadeTemplateChoice())
        #expect(WordTemplateSettings.templateMenuLabel() == "No template chosen")

        WordTemplateSettings.chooseBuiltInTemplateExplicitly()
        #expect(WordTemplateSettings.hasMadeTemplateChoice())
        #expect(!WordTemplateSettings.hasCustomTemplate())
        #expect(WordTemplateSettings.templateMenuLabel() == "Built-in template")
    }

    @Test("choosing a custom template counts as a choice made and is labeled 'Custom template'")
    func choosingCustomTemplateCountsAsMade() throws {
        WordTemplateSettings.restoreDefaultTemplate()
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfWordTemplateChoice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let sourceFile = sourceDir.appendingPathComponent("modello.docx")
        try makeSyntheticDocx().write(to: sourceFile)

        try WordTemplateSettings.chooseTemplate(at: sourceFile)
        #expect(WordTemplateSettings.hasMadeTemplateChoice())
        #expect(WordTemplateSettings.templateMenuLabel() == "Custom template")

        WordTemplateSettings.restoreDefaultTemplate()
    }

    @Test("a file that is not a ZIP archive is rejected, without touching the saved state")
    func rejectsNonZipFile() throws {
        WordTemplateSettings.restoreDefaultTemplate()
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent("LelePdfWordTemplateBad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let sourceFile = sourceDir.appendingPathComponent("non-uno-zip.docx")
        try Data("questo non è un archivio zip".utf8).write(to: sourceFile)

        #expect(throws: (any Error).self) {
            try WordTemplateSettings.chooseTemplate(at: sourceFile)
        }
        #expect(!WordTemplateSettings.hasCustomTemplate())
    }
}
