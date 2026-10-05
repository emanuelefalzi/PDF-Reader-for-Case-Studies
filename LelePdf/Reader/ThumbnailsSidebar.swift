import SwiftUI
@preconcurrency import PDFKit

/// The sidebar's "Pages" tab (SPEC §5.3): thumbnails with a dot for the
/// analysis state (`.none` placeholder until M5) and click to go to the
/// page.
struct ThumbnailsSidebar: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(0..<model.pageCount, id: \.self) { index in
                    ThumbnailRow(index: index)
                }
            }
            .padding(12)
        }
    }
}

private struct ThumbnailRow: View {
    let index: Int

    @Environment(DocumentModel.self) private var model
    @State private var image: NSImage?

    private var isCurrent: Bool { model.currentPageIndex == index }
    private var size: NSSize { model.thumbnailCache.thumbnailSize }

    var body: some View {
        let _ = PerfProbe.hit("swiftui.ThumbnailRow.body")
        Button {
            model.goToPage(index)
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            Rectangle().fill(Color.white)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .background(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isCurrent ? DSColor.accent : DSColor.borderThumbnail, lineWidth: isCurrent ? 2 : 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    AnalysisStatusDot(status: model.pageAnalysisStatus(at: index))
                        .padding(4)

                    // SPEC §5.13 "a small pen icon on the thumbnails of
                    // pages with annotations", in the corner opposite the
                    // analysis dot.
                    if model.annotationController.annotatedPages.contains(index) {
                        AnnotationBadge()
                            .padding(4)
                            .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                    }
                }
                Text("\(index + 1)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isCurrent ? DSColor.accent : DSColor.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .task(id: index) {
            image = await model.thumbnailCache.thumbnail(at: index)
        }
    }
}

/// Pen icon for a page with annotations (SPEC §5.13).
private struct AnnotationBadge: View {
    var body: some View {
        Image(systemName: "pencil.tip")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(DSColor.accent)
            .padding(2.5)
            .background(Circle().fill(.white))
    }
}

/// Placeholder for the full/half-full analysis dot (SPEC §5.3): `.none`
/// draws nothing until M5.
private struct AnalysisStatusDot: View {
    let status: PageAnalysisStatus

    var body: some View {
        switch status {
        case .none:
            EmptyView()
        case .partial:
            Circle().strokeBorder(DSColor.accent, lineWidth: 1.2).frame(width: 7, height: 7)
        case .full:
            Circle().fill(DSColor.accent).frame(width: 7, height: 7)
        }
    }
}
