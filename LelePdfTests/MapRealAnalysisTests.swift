import Foundation
import Testing
@testable import LelePdf

/// Read-only check on the real `analisi.json` files. The files are copied to
/// a temporary folder before decoding and no excerpt enters the repository
/// (M8 constraint).
///
/// It closes the gap between the older tests (node rectangles only) and the
/// map the user sees in the real app: here the link labels and the book
/// group headers are checked too, using the same text measurement as the
/// drawing (`MapTextMetrics`).
@Suite("Maps from real analyses")
struct MapRealAnalysisTests {
    @Test("deterministic layout with no overlaps (nodes, link labels, groups) for Merck and Draghi, chapter and book")
    func realAnalysesNoOverlap() throws {
        let sourceRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LelePdf-verifica", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceRoot.path) else { return }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LelePdf-map-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let folders = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var checked = 0
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
                blocks: document.blocks.map {
                    MapBlockSnapshot(id: $0.id, pageStart: $0.pageStart, pageEnd: $0.pageEnd)
                },
                toc: document.toc.entries.map {
                    MapTocSnapshot(id: $0.id, title: $0.title, level: $0.level, page: $0.page)
                },
                pageCount: document.pageCount
            )
            var checkedAnyScope = false
            for scope in MapScope.allCases {
                let graph = MapGraphBuilder.build(input: input, scope: scope, currentPage: document.progress.lastReadPage)
                guard !graph.nodes.isEmpty else { continue }
                let first = MapLayoutEngine.layout(graph)
                let second = MapLayoutEngine.layout(graph)
                #expect(first == second, "\(folder.lastPathComponent)/\(scope): non-deterministic layout")
                expectNoOverlap(first, context: "\(folder.lastPathComponent)/\(scope)")

                // Also the projection shown in the sidebar (12 nodes +
                // overflow, SPEC §5.3): fewer nodes but the same guarantee.
                let sidebar = MapSidebarProjection.project(graph)
                if sidebar.nodes.count < graph.nodes.count {
                    let sidebarLayout = MapLayoutEngine.layout(sidebar)
                    expectNoOverlap(sidebarLayout, context: "\(folder.lastPathComponent)/\(scope)/sidebar")
                }
                checkedAnyScope = true
            }
            if checkedAnyScope { checked += 1 }
        }
        #expect(checked >= 2, "expected at least the non-empty real analyses of Merck and Draghi")
    }

    /// No overlap between ANY pair of drawn elements: no longer just the node
    /// rectangles (the older tests satisfied "no overlap" in the strict sense
    /// but not what the user sees in the app, since they missed link labels
    /// and book group headers, SPEC §7.7).
    private func expectNoOverlap(_ layout: ConceptMapLayout, context: String) {
        let nodeRects = layout.nodeFrames.map {
            $0.rect.insetBy(dx: -MapLayoutEngine.nodePadding, dy: -MapLayoutEngine.nodePadding)
        }
        for left in nodeRects.indices {
            for right in nodeRects.indices where right > left {
                #expect(!nodeRects[left].intersects(nodeRects[right]), "\(context): node/node \(layout.nodeFrames[left].id)/\(layout.nodeFrames[right].id)")
            }
        }
        let labelRects = layout.edgeLabelFrames.map(\.rect)
        for label in layout.edgeLabelFrames {
            for nodeFrame in layout.nodeFrames {
                #expect(!label.rect.intersects(nodeFrame.rect), "\(context): label \(label.edgeID)/node \(nodeFrame.id)")
            }
        }
        for left in labelRects.indices {
            for right in labelRects.indices where right > left {
                #expect(!labelRects[left].intersects(labelRects[right]), "\(context): label/label \(layout.edgeLabelFrames[left].edgeID)/\(layout.edgeLabelFrames[right].edgeID)")
            }
        }
        for label in layout.edgeLabelFrames {
            for group in layout.groupFrames {
                #expect(
                    !label.rect.intersects(MapLayoutEngine.groupHeaderRect(group)),
                    "\(context): label \(label.edgeID)/group header \(group.id)"
                )
            }
        }
        for left in layout.groupFrames.indices {
            for right in layout.groupFrames.indices where right > left {
                #expect(!layout.groupFrames[left].rect.intersects(layout.groupFrames[right].rect), "\(context): group/group")
            }
        }
    }
}
