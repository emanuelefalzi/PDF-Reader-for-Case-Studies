import SwiftUI

/// Center column: the page/zoom bar plus the PDF (SPEC §5.1 "Center").
struct ReaderPane: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            PageZoomBar()
            if model.iCloudDownloading {
                iCloudBanner
            }
            if model.structure?.textlessPages == true {
                textlessBanner
            }
            PDFKitView(model: model)
        }
        .background(DSColor.windowBackground)
    }

    /// SPEC §8: "Downloading from iCloud…" while the Store waits for a data
    /// file that has not been downloaded yet.
    private var iCloudBanner: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Downloading from iCloud…")
                .font(.caption)
                .foregroundStyle(DSColor.textSecondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(DSColor.pageBarBackground)
    }

    /// SPEC §5.2 "PDF without text": `TextlessDetector` computes the flag,
    /// and this banner surfaces it. Reading stays possible; only the
    /// analysis is unavailable.
    private var textlessBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.orange)
            Text("This PDF has no selectable text: analysis is not available. You can add the text with an OCR program and reopen it.")
                .font(.caption)
                .foregroundStyle(DSColor.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
    }
}
