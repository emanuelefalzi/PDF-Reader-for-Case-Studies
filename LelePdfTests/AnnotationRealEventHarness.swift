import AppKit
import CoreText
import Foundation
import Testing
@preconcurrency import PDFKit
@testable import LelePdf

/// Real-event scene built in the same order as `PDFKitView.makeNSView`:
/// PDFView, mark fills, marks, annotations. All of the tests' interactions
/// go exclusively through `NSWindow.sendEvent`.
@MainActor
struct AnnotationRealEventHarness {
    enum WindowState: CaseIterable, CustomStringConvertible {
        case fresh
        case notYetKey

        var description: String {
            switch self {
            case .fresh: "fresh window"
            case .notYetKey: "window not yet key"
            }
        }
    }

    let sourceURL: URL
    let model: DocumentModel
    let pdfView: PDFView
    let window: NSWindow
    let rectangleOverlay: RectangleMarksOverlay
    let marksOverlay: MarksOverlayView
    let annotationOverlay: AnnotationOverlayView

    static let line = "Dentro o fuori dalla sezione analizzata"

    init(windowState: WindowState, withMark: Bool, insideAnalyzedSection: Bool) throws {
        sourceURL = try Self.makePDF()
        let data = try Data(contentsOf: sourceURL)
        model = try #require(DocumentModel(
            document: PDFFileDocument(data: data, displayName: sourceURL.lastPathComponent)
        ))
        pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        pdfView.document = model.pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = false
        pdfView.scaleFactor = 1

        window = NSWindow(
            contentRect: pdfView.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = pdfView

        rectangleOverlay = RectangleMarksOverlay(model: model, pdfView: pdfView)
        rectangleOverlay.frame = pdfView.bounds
        marksOverlay = MarksOverlayView(model: model, pdfView: pdfView)
        marksOverlay.frame = pdfView.bounds
        rectangleOverlay.host = marksOverlay
        marksOverlay.rectangleOverlay = rectangleOverlay
        annotationOverlay = AnnotationOverlayView(model: model, pdfView: pdfView)
        annotationOverlay.frame = pdfView.bounds

        pdfView.addSubview(rectangleOverlay)
        pdfView.addSubview(marksOverlay)
        pdfView.addSubview(annotationOverlay)
        model.readerBridge = PDFReaderBridge(pdfView: pdfView)
        model.visiblePageRange = 0 ... 0
        seedContext(withMark: withMark, analyzed: insideAnalyzedSection)

        window.layoutIfNeeded()
        switch windowState {
        case .fresh:
            window.makeKeyAndOrderFront(nil)
        case .notYetKey:
            // Ordered (so it gets the normal AppKit hit-testing), but never made
            // key: it is the first real click that must work.
            window.orderFront(nil)
        }
        for _ in 0 ..< 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func teardown() {
        annotationOverlay.stopObserving()
        marksOverlay.stopObserving()
        annotationOverlay.removeFromSuperview()
        marksOverlay.removeFromSuperview()
        rectangleOverlay.removeFromSuperview()
        window.contentView = nil
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
        for _ in 0 ..< 3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func drag(from startPagePoint: CGPoint, to endPagePoint: CGPoint, steps: Int = 4) {
        guard let page = model.pdfDocument.page(at: 0) else {
            Issue.record("synthetic page missing")
            return
        }
        let start = annotationOverlay.convert(pdfView.convert(startPagePoint, from: page), to: nil)
        let end = annotationOverlay.convert(pdfView.convert(endPagePoint, from: page), to: nil)
        window.sendEvent(mouseEvent(.leftMouseDown, at: start))
        for step in 1 ... max(steps, 1) {
            let t = CGFloat(step) / CGFloat(max(steps, 1))
            let point = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            window.sendEvent(mouseEvent(.leftMouseDragged, at: point))
        }
        window.sendEvent(mouseEvent(.leftMouseUp, at: end, pressure: 0))
    }

    func textDragRange() throws -> (start: CGPoint, end: CGPoint) {
        let page = try #require(model.pdfDocument.page(at: 0))
        let selection = try #require(page.selection(for: NSRange(location: 0, length: 18)))
        let rect = selection.bounds(for: page)
        return (
            CGPoint(x: rect.minX + 1, y: rect.midY),
            CGPoint(x: rect.maxX - 1, y: rect.midY)
        )
    }

    func ownedPDFAnnotation(id: String) -> PDFAnnotation? {
        model.pdfDocument.page(at: 0)?.annotations.first {
            PDFAnnotationOwnership.tag(of: $0) == .init(role: .freeAnnotation, id: id)
        }
    }

    func hasMark(at pagePoint: CGPoint) -> Bool {
        model.analysisController.markItems(forPage: 0, document: model.pdfDocument)
            .contains { item in
                item.lineRects.contains(where: { rect in rect.contains(pagePoint) })
            }
    }

    var sectionIsAnalyzed: Bool {
        model.analysisController.context?.analysis.blocks["b1"]?.status == .analyzed
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, at point: CGPoint, pressure: Float = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: pressure
        )!
    }

    private func seedContext(withMark: Bool, analyzed: Bool) {
        let text = model.pdfDocument.page(at: 0)?.string ?? Self.line
        let block = TextBlock(
            id: "b1", sectionPath: [], pageStart: 0, pageEnd: 0,
            cleanText: text, textHash: "b1", words: text.split(separator: " ").count,
            spans: [BlockPageSpan(
                page: 0, cleanStart: 0, cleanLength: text.count,
                charMap: Array(0 ..< text.count)
            )],
            lineRectsByPage: [:]
        )
        var analysis = AnalysisRecord()
        analysis.blocks["b1"] = BlockAnalysis(
            status: analyzed ? .analyzed : .other("manual"),
            marks: withMark ? [Mark(
                id: "m1", termId: "t1", type: .rectangle,
                text: "Dentro o fuori", source: .manual, page: 0,
                range: MarkRange(start: 0, length: 14)
            )] : []
        )
        model.analysisController.updateContext(
            fingerprint: "fp-eventi-f5", documentTitle: "Eventi F5",
            blocks: [block], exhibits: [], analysis: analysis,
            lastAnalyzedBlockId: analyzed ? "b1" : nil, tocEntries: []
        )
    }

    private static func makePDF() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LelePdf-eventi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("eventi.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 360, height: 240)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: line, attributes: [.font: NSFont.systemFont(ofSize: 15)]
        )
        context.textPosition = CGPoint(x: 30, y: 150)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
        return url
    }
}
