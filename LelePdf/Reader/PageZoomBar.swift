import SwiftUI

/// "Page 42 of 612 · Zoom 118%" bar above the PDF (SPEC §5.1, design: a
/// 34 px tall row). The design's "Highlight by active category" items are
/// not here yet (they arrive with the marks in M5).
struct PageZoomBar: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.saveMarksIntoPDF()
            } label: {
                Label("Save the marks in the PDF", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canWriteOriginalPDF || model.pdfSaveState == .saving)

            if model.pdfSaveState == .saving {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Text("Page \(model.currentPageIndex + 1) of \(model.pageCount)")
            Divider().frame(height: 12)
            HStack(spacing: 6) {
                Button {
                    model.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)

                Text("Zoom \(model.zoomPercent)%")

                Button {
                    model.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
            }
            Spacer()
            saveStatus
        }
        .font(.system(size: 11.5))
        .foregroundStyle(DSColor.textSecondary)
        .frame(height: DSMetrics.pageZoomBarHeight)
        .frame(maxWidth: .infinity)
        .background(DSColor.pageBarBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DSColor.borderStrong).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch model.pdfSaveState {
        case .idle, .saving:
            EmptyView()
        case .saved(let message):
            Text(message).foregroundStyle(DSColor.textSecondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(message)
        }
    }
}
