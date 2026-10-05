import Foundation
import Observation

/// State of the Summary Lab (SPEC §5.14). Reads the open document from
/// `OpenDocuments.shared.active` (M10: the window lives in a separate
/// `Scene`, not in `DocumentWindowView`'s environment) and never modifies
/// it: the "New Trial" goes through `LaboratorioTrial`, which does not
/// receive a `DocumentStore` and so cannot save anything by construction.
@MainActor
@Observable
final class LaboratorioViewModel {
    var instructionsText: String = ""
    private(set) var hasCustomFile: Bool = false
    var selectedBlockId: String? {
        didSet {
            // Changing block clears the previous "New Trial": still showing it next
            // to a different block would confuse the comparison (SPEC §5.14 "the
            // choice of a block ... and two columns", implicitly referring to the
            // SAME block).
            guard oldValue != selectedBlockId else { return }
            trialOutput = nil
            trialError = nil
        }
    }
    private(set) var isRunningTrial = false
    private(set) var trialOutput: AnalysisPostProcessor.Output?
    private(set) var trialError: String?
    var saveWarning: String?
    var statusMessage: String?

    private var dataFolderURL: URL { AppStore.shared.dataFolderURL }
    private let openDocuments: OpenDocuments

    var document: DocumentModel? { openDocuments.active }

    init(openDocuments: OpenDocuments = .shared) {
        self.openDocuments = openDocuments
        reloadInstructions()
        selectedBlockId = document?.analysisController.readingPositionBlock(
            currentPageIndex: document?.currentPageIndex ?? 0
        ) ?? blocks.first?.id
    }

    func reloadInstructions() {
        instructionsText = AnalysisInstructions.effectiveText(dataFolderURL: dataFolderURL)
        hasCustomFile = AnalysisInstructions.hasCustom(dataFolderURL: dataFolderURL)
    }

    /// "Restore the Original Instructions" (SPEC §5.14, on the left): only
    /// the text in the editor, it does not touch the custom file on disk;
    /// for that there is "Restore" next to "Save as Default".
    func resetEditorToOriginal() {
        instructionsText = AnalysisInstructions.bundledText()
        saveWarning = nil
    }

    func saveAsDefault() {
        saveWarning = AnalysisInstructions.missingFormatWarning(instructionsText)
        do {
            try AnalysisInstructions.save(instructionsText, dataFolderURL: dataFolderURL)
            hasCustomFile = true
            statusMessage = String(localized: "Saved. New analyses will now use these instructions.")
        } catch {
            statusMessage = String(localized: "Can't save: \(error.localizedDescription)")
        }
    }

    func restoreDefault() {
        do {
            try AnalysisInstructions.restore(dataFolderURL: dataFolderURL)
            hasCustomFile = false
            instructionsText = AnalysisInstructions.bundledText()
            saveWarning = nil
            statusMessage = String(localized: "Restored the default instructions.")
        } catch {
            statusMessage = String(localized: "Can't restore: \(error.localizedDescription)")
        }
    }

    // MARK: - Block (SPEC §5.14 "the choice of a block of the open PDF")

    var blocks: [TextBlock] { document?.analysisController.context?.blocks ?? [] }

    func label(for block: TextBlock) -> String {
        document?.analysisController.humanBlockLabel(for: block.id) ?? block.id
    }

    var selectedBlock: TextBlock? {
        guard let selectedBlockId else { return nil }
        return blocks.first { $0.id == selectedBlockId }
    }

    var blockWordCount: Int? { selectedBlock?.words }

    /// "Current Version" (SPEC §5.14): the already saved rewrite, if the
    /// block has already been analyzed. Same `cardData` as the real right
    /// panel, to be "rendered like the right-panel cards" without
    /// duplicating the marker resolution.
    var currentVersion: AnalysisController.BlockCardData? {
        guard let selectedBlockId else { return nil }
        return document?.analysisController.cardData(for: selectedBlockId)
    }

    var currentVersionWordCount: Int? {
        guard let selectedBlockId, let context = document?.analysisController.context,
              let analyzed = context.analysis.blocks[selectedBlockId], analyzed.status == .analyzed
        else { return nil }
        return WordCount.count(RewritePlainText.render(analyzed.rewrite))
    }

    // MARK: - Trial (SPEC §5.14 "a real call to Claude, counted")

    var trialCard: AnalysisController.BlockCardData? {
        trialOutput.map(RewriteResolution.card(from:))
    }

    var trialWordCount: Int? {
        trialOutput.map { WordCount.count(RewritePlainText.render($0.rewrite)) }
    }

    var canRunTrial: Bool {
        !isRunningTrial && selectedBlock != nil && !instructionsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func runTrial() async {
        guard let document, let context = document.analysisController.context, let block = selectedBlock else { return }
        isRunningTrial = true
        trialError = nil
        defer { isRunningTrial = false }

        let previousSummary = AnalysisInputBuilder.previousBlockSummary(blocks: context.blocks, analysis: context.analysis, blockId: block.id)
        let glossary = GlossaryBuilder.build(analysis: context.analysis, blockOrder: context.blocks.map(\.id))
        let request = LaboratorioTrial.Request(
            documentTitle: context.documentTitle,
            block: block,
            previousBlockSummary: previousSummary,
            glossary: glossary,
            exhibits: context.exhibits,
            existingTerms: context.analysis.terms,
            instructions: instructionsText,
            model: AnalysisModelPreference.read(defaults: AppRuntime.defaults)
        )
        let outcome = await LaboratorioTrial.run(request, runner: BatchRunner.shared)
        switch outcome {
        case .success(let output):
            trialOutput = output
        case .failure(let error):
            trialOutput = nil
            trialError = error.userMessage
        }
    }
}
