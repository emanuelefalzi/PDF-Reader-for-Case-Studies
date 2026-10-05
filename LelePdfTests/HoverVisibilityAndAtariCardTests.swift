import Foundation
import AppKit
import SwiftUI
import Testing
@testable import LelePdf

/// Two further fixes reported after the first round of work: (1) "hovering
/// over words ... is still buggy and not very clear"
/// (`MarkGeometry.strokeBonus`/`fillDarkenFraction`,
/// `NSColor.darkened(by:)`); (2) a second real screenshot (card "Atari's Rise
/// and Loss of Control", panel ~470 pt) with the same overlap bug as the
/// first, but on `summary`+`bullets` instead of `paragraph`+`table`+
/// `paragraph`, plus an arrow "→" drawn twice in cause→effect bullet points.
/// This file verifies both.
extension HeavyTestSuites {
@MainActor
@Suite("Clearer hover and Atari card with no overlaps", .serialized)
struct HoverVisibilityAndAtariCardTests {
    private func makeModel() throws -> DocumentModel {
        let sourceURL = try StoreFixtures.makeTextPDF(text: "Documento di prova.", fileName: "hover-atari-\(UUID().uuidString).pdf")
        let data = try Data(contentsOf: sourceURL)
        let fileDocument = PDFFileDocument(data: data, displayName: "hover-atari-test")
        return try #require(DocumentModel(document: fileDocument, fileURL: sourceURL))
    }

    // MARK: - Clearer hover

    /// Renders a card with ONE normal mark and ONE hovered mark (same type,
    /// same base color; only the state changes): the difference must be
    /// visible to the eye in the PNG (darker and thicker stroke/fill), not
    /// require a pixel-by-pixel comparison. Also verifies at the data level
    /// (not only visually) that the states really differ by construction.
    @Test("a hovered mark is clearly more pronounced than a normal one (same card, same type)")
    func hoverMarkIsClearlyEmphasized() throws {
        let model = try makeModel()
        model.setHover(termId: "t-hover", markId: "m-hover", blockId: "hover-demo") // the "counterpart on the other side" (SPEC §5.8)

        let items: [AnalysisController.ResolvedRewriteItem] = [
            .init(kind: .paragraph, segments: [
                .plain("Il segno "),
                .marked(text: "normale", markId: "m-normal", termId: "t-normal", type: .rectangle),
                .plain(" non è sotto il mouse; il segno "),
                .marked(text: "in evidenza", markId: "m-hover", termId: "t-hover", type: .rectangle),
                .plain(" lo è."),
            ], itemSegments: nil, columns: nil, rowSegments: nil),
        ]
        var collected: [Int: CGRect] = [:]
        let probe = CardItemsProbe(items: items, model: model, blockId: "hover-demo") { collected = $0 }
            .frame(width: 320, alignment: .leading)
            .background(Color.white)
        let hostingView = NSHostingView(rootView: probe)
        hostingView.frame = CGRect(x: 0, y: 0, width: 320, height: 1)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        hostingView.frame = CGRect(x: 0, y: 0, width: 320, height: max(1, fitting.height))
        window.setContentSize(hostingView.frame.size)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        exportPNG(hostingView, to: outputRoot.appendingPathComponent("hover-normal-vs-linked.png"))

        #expect(!collected.isEmpty)

        // Data check, independent of the PNG: the states computed for the two
        // marks really differ, and the difference (thicker stroke, darker
        // color) is notable (thresholds: stroke 1.5-2pt, darkening > 0.15).
        let normalState = HoverLinking.state(markId: "m-normal", blockId: "hover-demo", termId: "t-normal", isRepetition: false, hoveredMarkId: model.hoveredMarkId, hoveredBlockId: model.hoveredMarkBlockId, hoveredTermId: model.hoveredTermId)
        let hoverState = HoverLinking.state(markId: "m-hover", blockId: "hover-demo", termId: "t-hover", isRepetition: false, hoveredMarkId: model.hoveredMarkId, hoveredBlockId: model.hoveredMarkBlockId, hoveredTermId: model.hoveredTermId)
        #expect(normalState == .normal)
        #expect(hoverState == .hover)
        let strokeDelta = MarkGeometry.strokeBonus(for: hoverState) - MarkGeometry.strokeBonus(for: normalState)
        #expect(strokeDelta >= 1.5 && strokeDelta <= 2.0, "stroke difference outside the required 1.5-2pt range: \(strokeDelta)")
        #expect(MarkGeometry.fillDarkenFraction(for: hoverState) > 0.15)
        #expect(MarkGeometry.fillDarkenFraction(for: normalState) == 0)
    }

    // MARK: - "Atari" card (summary + bullets with →, plus mixed marks)

    /// Same scheme as the second screenshot: a `summary` (paragraph) followed
    /// by a `bullets` with a cause→effect row (which in production arrives
    /// with "→ " at the start; the two historical variants "→"/"->" are
    /// tested here too) and marks of all 4 types scattered in the text. Used
    /// at the 4 panel widths required.
    private func makeAtariItems() -> [AnalysisController.ResolvedRewriteItem] {
        [
            .init(kind: .summary, segments: [
                .plain("Atari dominated the early videogame market with "),
                .marked(text: "Pong", markId: "m1", termId: "t1", type: .rectangle),
                .plain(" before losing control over third-party game development."),
            ], itemSegments: nil, columns: nil, rowSegments: nil),
            .init(kind: .bullets, segments: nil, itemSegments: [
                [.plain("Atari held an "), .marked(text: "80% share of the videogame market", markId: "m2", termId: "t2", type: .circle), .plain(" in 1980.")],
                [.plain("The "), .marked(text: "Channel F", markId: "m3", termId: "t3", type: .rectangle), .plain(" was a rival console from Fairchild.")],
                // The three historical variants of the arrow prefix (all three must be handled the same way).
                [.plain("→ "), .marked(text: "Licensing Space Invaders", markId: "m4", termId: "t4", type: .underline), .plain(" fueled joystick and cartridge sales.")],
                [.plain("→"), .plain(" Former employees who "), .marked(text: "left to found Activision", markId: "m5", termId: "t5", type: .arrow), .plain(" started third-party publishing.")],
                [.plain("-> "), .plain("A flooded market of low-quality cartridges followed.")],
            ], columns: nil, rowSegments: nil),
        ]
    }

    @Test("Atari card (summary + bullets with →, mixed marks): no overlaps at 320/392/470/520 pt", arguments: [CGFloat(320), CGFloat(392), CGFloat(470), CGFloat(520)])
    func atariCardHasNoOverlapAndNoDoubleArrow(panelWidth: CGFloat) throws {
        let model = try makeModel()
        let items = makeAtariItems()
        var collected: [Int: CGRect] = [:]
        let probe = CardItemsProbe(items: items, model: model, blockId: "atari") { collected = $0 }
            .frame(width: panelWidth, alignment: .leading)
            .background(Color.white)
        let hostingView = NSHostingView(rootView: probe)
        hostingView.frame = CGRect(x: 0, y: 0, width: panelWidth, height: 1)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { closeTestWindow(window) }
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        hostingView.frame = CGRect(x: 0, y: 0, width: panelWidth, height: max(1, fitting.height))
        window.setContentSize(hostingView.frame.size)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let outputRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/verifica-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        exportPNG(hostingView, to: outputRoot.appendingPathComponent("card-atari-\(Int(panelWidth))pt.png"))

        let frames = (0 ..< items.count).map { collected[$0] ?? .zero }
        #expect(frames.allSatisfy { $0.height > 0 }, "an item has zero height at \(panelWidth) pt: \(frames)")
        for i in 0 ..< frames.count {
            for j in (i + 1) ..< frames.count where j > i {
                #expect(!frames[i].intersects(frames[j]), "items \(i)/\(j) overlap at \(panelWidth) pt: \(frames[i]) vs \(frames[j])")
            }
        }

        // No double arrow ("keep only one"): the displayed text of EVERY list
        // row, after `strippingLeadingArrowMarker`, must no longer start with
        // the arrow character; only the icon in the margin represents it.
        if let bulletsItem = items.first(where: { $0.kind == .bullets }), let rows = bulletsItem.itemSegments {
            for row in rows {
                let (isArrow, cleaned) = RewriteViewModel.strippingLeadingArrowMarker(row)
                let cleanedText = MarkedTextBuilder.build(cleaned).text
                if isArrow {
                    #expect(!cleanedText.hasPrefix("→"), "arrow still in the text after cleaning: \"\(cleanedText)\"")
                    #expect(!cleanedText.hasPrefix("->"), "ASCII arrow still in the text after cleaning: \"\(cleanedText)\"")
                }
            }
            // The three rows written with an arrow prefix are really
            // recognized as such (not just the first two).
            let arrowFlags = rows.map { RewriteViewModel.strippingLeadingArrowMarker($0).isArrow }
            #expect(arrowFlags.filter { $0 }.count == 3, "expected 3 cause→effect rows recognized, found \(arrowFlags.filter { $0 }.count)")
        }
    }
}
}
