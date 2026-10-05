import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// Exports a PNG of the map drawn with real data (Merck/Draghi), using the
/// app's own `MapCanvasView`/`MapTextMetrics`, just off screen: the F1 brief
/// forbids launching the real GUI on the shared Mac, so this is the visual
/// check provided as an alternative. The PNGs stay in a local cache, never in
/// the repository.
// `.serialized`: creates real `NSWindow`/`NSHostingView` instances, same
// reason as `RewritePanelRealContentLayoutTests`/`RewriteScrollHostTests`.
extension HeavyTestSuites {
@MainActor
@Suite("Real map · PNG export for visual inspection", .serialized)
struct MapRenderExportTests {
    @Test("sidebar and expanded map of the real Merck/Draghi analyses")
    func exportRealMapsForInspection() throws {
        let sourceRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LelePdf-verifica", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceRoot.path) else { return }

        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LelePdf-map-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let folders = try FileManager.default.contentsOfDirectory(
            at: sourceRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        let model = try makeBareModel()
        var exported = 0
        for (index, folder) in folders.enumerated() {
            let analysisSource = folder.appendingPathComponent("analisi.json")
            let documentSource = folder.appendingPathComponent("documento.json")
            guard FileManager.default.fileExists(atPath: analysisSource.path),
                  FileManager.default.fileExists(atPath: documentSource.path) else { continue }
            let copy = temporaryRoot.appendingPathComponent("case-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            let analysisURL = copy.appendingPathComponent("analisi.json")
            let documentURL = copy.appendingPathComponent("documento.json")
            try FileManager.default.copyItem(at: analysisSource, to: analysisURL)
            try FileManager.default.copyItem(at: documentSource, to: documentURL)
            guard let analysis = AtomicJSONFile.decode(AnalysisRecord.self, from: analysisURL),
                  let document = AtomicJSONFile.decode(DocumentRecord.self, from: documentURL),
                  !analysis.blocks.isEmpty else { continue }
            let input = MapGraphInput(
                analysis: analysis,
                blocks: document.blocks.map { MapBlockSnapshot(id: $0.id, pageStart: $0.pageStart, pageEnd: $0.pageEnd) },
                toc: document.toc.entries.map { MapTocSnapshot(id: $0.id, title: $0.title, level: $0.level, page: $0.page) },
                pageCount: document.pageCount
            )
            // Prefix with the index: two real folders (two analyses of the
            // Merck case at different times) share the same truncated title and
            // would otherwise overwrite each other.
            let safeName = "\(index)-" + String(folder.lastPathComponent
                .replacingOccurrences(of: "/", with: "-")
                .prefix(40))

            for scope in MapScope.allCases {
                let graph = MapGraphBuilder.build(input: input, scope: scope, currentPage: document.progress.lastReadPage)
                guard !graph.nodes.isEmpty else { continue }

                // Sidebar: small card like `MapSidebarView.mapCard`.
                let sidebarGraph = MapSidebarProjection.project(graph)
                let sidebarLayout = MapLayoutEngine.layout(sidebarGraph)
                try render(
                    graph: sidebarGraph, layout: sidebarLayout, size: CGSize(width: 236, height: 300), model: model,
                    to: outputRoot.appendingPathComponent("\(safeName)-\(scope)-sidebar.png")
                )
                // Expanded: typical window size.
                let layout = MapLayoutEngine.layout(graph)
                try render(
                    graph: graph, layout: layout, size: CGSize(width: 1100, height: 760), model: model,
                    to: outputRoot.appendingPathComponent("\(safeName)-\(scope)-expanded.png")
                )
                exported += 1
            }
        }
        #expect(exported >= 2, "expected at least one export for Merck and Draghi")
    }

    private func makeBareModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(
            text: "Documento vuoto solo per l'ambiente della vista mappa.",
            fileName: "map-render-\(UUID().uuidString).pdf"
        )
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "map-render-test")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }

    private func render(
        graph: ConceptMapGraph, layout: ConceptMapLayout, size: CGSize, model: DocumentModel, to url: URL
    ) throws {
        // Per-test memory guard.
        try expectFootprintGrowthUnderGuard("MapRenderExportTests.render(\(url.lastPathComponent))") {
        let hostingView = NSHostingView(rootView:
            MapCanvasView(
                graph: graph, layout: layout, interactiveViewport: false,
                zoom: .constant(1), pan: .constant(.zero), onHover: { _ in }, onSelect: { _ in }
            )
            .environment(model)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
        )
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false // never explicitly closed in this test.
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        // Temporary capture bitmap, released right away (see `exportPNG` in
        // CardItemOverlapTests.swift, same reason).
        try autoreleasepool {
            guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return }
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try png.write(to: url)
        }
        }
    }
}
}
