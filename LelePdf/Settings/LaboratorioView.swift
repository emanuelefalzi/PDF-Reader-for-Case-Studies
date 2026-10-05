import SwiftUI

/// "Summary Lab" window (SPEC §5.14): the instructions for Claude on the
/// left, the comparison on a block of the open PDF on the right. The user
/// is not a programmer: nothing here assumes the ability to read code,
/// only prose text and two columns to compare by eye.
struct LaboratorioView: View {
    static let windowID = "laboratorio"

    @State private var viewModel = LaboratorioViewModel()

    var body: some View {
        HSplitView {
            instructionsPane
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)
            rightPane
                .frame(minWidth: 420)
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { viewModel.reloadInstructions() }
    }

    @ViewBuilder
    private var rightPane: some View {
        if let document = viewModel.document {
            LaboratorioColumnsView(viewModel: viewModel, document: document)
        } else {
            noDocumentState
        }
    }

    private var noDocumentState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(DSColor.textTertiary)
            Text("Open a PDF to choose a block to try.")
                .foregroundStyle(DSColor.textSecondary)
            Text("The instructions on the left can still be edited and saved.")
                .font(.caption)
                .foregroundStyle(DSColor.textTertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var instructionsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Instructions for Claude")
                .font(.system(size: 13, weight: .semibold))
            Text("How Claude rewrites each block (SPEC §5.14). The data format stays fixed: only this text changes.")
                .font(.caption)
                .foregroundStyle(DSColor.textSecondary)
            TextEditor(text: $viewModel.instructionsText)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(DSColor.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard).stroke(DSColor.borderCard, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: DSMetrics.cornerRadiusCard))
                .frame(minHeight: 260)

            HStack {
                Button("Restore the Original Instructions") { viewModel.resetEditorToOriginal() }
                Spacer()
                if viewModel.hasCustomFile {
                    Label("Customized", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if let warning = viewModel.saveWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button("Save as Default") { viewModel.saveAsDefault() }
                    .disabled(viewModel.instructionsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Restore") { viewModel.restoreDefault() }
                    .disabled(!viewModel.hasCustomFile)
            }

            if let statusMessage = viewModel.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .padding(14)
    }
}
