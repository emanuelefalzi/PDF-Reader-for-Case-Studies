import SwiftUI
@preconcurrency import PDFKit

/// Root view of a document window (SPEC §5.1). Creates the
/// `DocumentModel` once per window (SPEC §6.3) and mounts the 3-column
/// layout plus the toolbar.
struct DocumentWindowView: View {
    @State private var model: DocumentModel?
    private let document: PDFFileDocument

    init(document: PDFFileDocument, fileURL: URL? = nil) {
        self.document = document
        _model = State(initialValue: DocumentModel(document: document, fileURL: fileURL))
    }

    var body: some View {
        Group {
            if let model {
                VStack(spacing: 0) {
                    // SPEC §5.13 "Opens the tools bar below the toolbar; when closed,
                    // the PDF goes back to normal reading".
                    if model.annotationController.barVisible {
                        AnnotationToolbarBar()
                    }
                    ThreePaneLayout()
                }
                    .toolbar { WindowToolbarContent() }
                    .environment(model)
                    .focusedSceneValue(\.documentModel, model)
                    .background(WindowKeyObserver { OpenDocuments.shared.markActive(model) })
                    .onAppear { OpenDocuments.shared.register(model) }
                    .onDisappear {
                        model.flushStore()
                        Task { await model.chatController.closeWindow() }
                        model.syncCoordinator.detach()
                        OpenDocuments.shared.unregister(model)
                    }
            } else {
                unreadablePDF
            }
        }
        .frame(minWidth: DSMetrics.minWindowWidth, minHeight: DSMetrics.minWindowHeight)
    }

    private var unreadablePDF: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Can't read \(document.displayName)")
                .font(.title3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
