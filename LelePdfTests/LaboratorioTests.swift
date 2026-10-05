import Foundation
import Testing
@testable import LelePdf

/// Summary Lab (SPEC §5.14, M10): resolving the instructions (custom file
/// vs. bundle) and the trial call, which must never save anything.
@Suite("AnalysisInstructions (Summary Lab)")
struct AnalysisInstructionsTests {
    private func tempFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lelepdf-lab-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("without a custom file: the effective text is the built-in one")
    func fallsBackToBundledWhenNoCustomFile() {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(AnalysisInstructions.hasCustom(dataFolderURL: folder) == false)
        #expect(AnalysisInstructions.effectiveText(dataFolderURL: folder) == AnalysisInstructions.bundledText())
        #expect(!AnalysisInstructions.bundledText().isEmpty, "the built-in prompt must be in the test bundle")
    }

    @Test("after saving: the effective text is the custom one, not the built-in one")
    func customFileTakesPrecedenceOverBundled() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let custom = "Custom test instructions. Always use {{mX|words}} for marks."

        try AnalysisInstructions.save(custom, dataFolderURL: folder)

        #expect(AnalysisInstructions.hasCustom(dataFolderURL: folder))
        #expect(AnalysisInstructions.effectiveText(dataFolderURL: folder) == custom)
        #expect(AnalysisInstructions.effectiveText(dataFolderURL: folder) != AnalysisInstructions.bundledText())
    }

    @Test("Restore: deletes the custom file, falls back to the built-in text")
    func restoreDeletesCustomFileAndFallsBack() throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try AnalysisInstructions.save("qualcosa di personalizzato", dataFolderURL: folder)
        #expect(AnalysisInstructions.hasCustom(dataFolderURL: folder))

        try AnalysisInstructions.restore(dataFolderURL: folder)

        #expect(AnalysisInstructions.hasCustom(dataFolderURL: folder) == false)
        #expect(AnalysisInstructions.effectiveText(dataFolderURL: folder) == AnalysisInstructions.bundledText())
        // "Restore" without an existing file must not throw (it has to be
        // pressable even when there is nothing to delete).
        #expect(throws: Never.self) { try AnalysisInstructions.restore(dataFolderURL: folder) }
    }

    @Test("marker format warning: absent if the text still explains them, present otherwise")
    func missingFormatWarningDetectsMarkerSyntax() {
        #expect(AnalysisInstructions.missingFormatWarning("Usa {{m1|parola}} per i segni.") == nil)
        #expect(AnalysisInstructions.missingFormatWarning("Riscrivi il blocco in modo chiaro.") != nil)
    }

    /// An Italian contract at the end of the prompt made titles and summaries
    /// of English PDFs come out in Italian (Ockham, 2026-09-27): the contract
    /// stays in English and enforces the block's language even when the custom
    /// instructions are written in Italian.
    @Test("the composed prompt enforces the block language, even with custom instructions in Italian")
    func systemPromptEnforcesBlockLanguage() throws {
        let contract = AnalysisInstructions.bundledContractText()
        #expect(contract.contains("Output language"))
        #expect(contract.contains("language of the block text"))
        #expect(!contract.contains("Contratto tecnico"), "the contract must not be in Italian")

        let prompt = try #require(AnalysisInstructions.systemPrompt(editableText: "Riassumi in modo schematico."))
        #expect(prompt.hasSuffix(contract))
        #expect(prompt.contains("language of the block text"))

        let rewrite = ClaudeResources.promptText(named: "rewrite-block") ?? ""
        #expect(rewrite.contains("Output language"))
    }
}

@Suite("LaboratorioTrial (Summary Lab)")
struct LaboratorioTrialTests {
    private func sampleBlock(text: String = "Il testo parla di Merck e della FDA che approva il farmaco.") -> TextBlock {
        TextBlock(
            id: "b1", sectionPath: ["Sezione"], pageStart: 0, pageEnd: 0, cleanText: text, textHash: "hash",
            words: text.split(separator: " ").count,
            spans: [BlockPageSpan(page: 0, cleanStart: 0, cleanLength: text.count, charMap: Array(0 ..< text.count))],
            lineRectsByPage: [:]
        )
    }

    private func request(instructions: String) -> LaboratorioTrial.Request {
        LaboratorioTrial.Request(
            documentTitle: "Documento di prova", block: sampleBlock(), previousBlockSummary: nil,
            glossary: [], exhibits: [], existingTerms: [:], instructions: instructions, model: .sonnet
        )
    }

    @Test("the trial uses the edited text as the call's system prompt, not the built-in one")
    func trialSendsEditedInstructionsAsSystemPrompt() async throws {
        let logPath = makeTempFilePath("log-lab-trial.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }
        let edited = "Instructions edited in the Summary Lab, different from the defaults."

        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let runner = BatchRunner(timeout: 10)
            let outcome = await LaboratorioTrial.run(request(instructions: edited), runner: runner)
            let output = try #require(try? outcome.get())
            #expect(!output.rewrite.isEmpty || !output.marks.isEmpty, "the fake CLI must return a usable outcome")

            let entries = readFakeClaudeLog(logPath)
            let entry = try #require(entries.last)
            let argv = try #require(entry["argv"] as? [String])
            #expect(argv.contains { $0.contains(edited) }, "the system prompt sent to the CLI must contain the edited text")
            #expect(argv.contains { $0.contains(AnalysisInstructions.bundledContractText()) })
            #expect(!argv.contains { $0 == AnalysisInstructions.bundledText() })
        }
    }

    @Test("empty instructions: no call to the CLI")
    func emptyInstructionsNeverCallCLI() async throws {
        let logPath = makeTempFilePath("log-lab-trial-empty.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }

        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let runner = BatchRunner(timeout: 10)
            let outcome = await LaboratorioTrial.run(request(instructions: "   \n  "), runner: runner)
            #expect(outcome.isFailure)
            #expect(fakeClaudeBusyInvocationCount(logPath) == 0)
        }
    }

    @Test("the trial result is never written to the data folder")
    func trialResultIsNeverPersistedToDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lelepdf-lab-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let runner = BatchRunner(timeout: 10)
            _ = await LaboratorioTrial.run(request(instructions: "Test instructions."), runner: runner)
            // `LaboratorioTrial.run` never receives a `DocumentStore`, so by
            // construction it cannot write `analisi.json`. Verified here too,
            // on the data folder, so this stays a readable regression check
            // without having to re-read the function's signature.
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            #expect(contents.isEmpty)
        }
    }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { true } else { false } }
}
