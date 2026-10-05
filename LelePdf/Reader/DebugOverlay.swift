import AppKit
@preconcurrency import PDFKit

/// Debug overlay (SPEC §11 row M2, Debug menu › "Show blocks"): draws the
/// block boundaries, headings and Exhibits on top of the PDF using
/// temporary `PDFAnnotation`s that are never written to the file (the app
/// stays read-only, SPEC §2: the annotations live only in the in-memory
/// `PDFDocument` and are removed when the toggle is switched off or the
/// pipeline republishes the structure).
///
/// [TECHNICAL CHOICE]: SPEC §7.1/§4 pointed to
/// `PDFView.pageOverlayViewProvider`, which exists in the SDK, but in
/// practice (`PDFView` inside an `NSViewRepresentable`, `singlePageContinuous`
/// mode) PDFKit never calls the `overlayViewFor` method, with or without an
/// explicit `layoutDocumentView()` or a forced scroll. Annotations are a
/// simpler PDFKit mechanism that reliably draws on top of the pages; M5
/// will reassess whether the real marks stay on this path.
@MainActor
final class DebugBlockAnnotator {
    private weak var document: PDFDocument?
    private var addedAnnotations: [ObjectIdentifier: [PDFAnnotation]] = [:]

    init(document: PDFDocument) {
        self.document = document
    }

    func update(structure: DocumentStructure?, show: Bool) {
        clear()
        guard show, let structure, let document else { return }
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            var annotations: [PDFAnnotation] = []
            annotations.append(contentsOf: removedLineAnnotations(structure, pageIndex: pageIndex))
            annotations.append(contentsOf: blockAnnotations(structure, pageIndex: pageIndex))
            annotations.append(contentsOf: headingAnnotations(structure, pageIndex: pageIndex))
            annotations.append(contentsOf: exhibitAnnotations(structure, pageIndex: pageIndex))
            guard !annotations.isEmpty else { continue }
            for annotation in annotations { page.addAnnotation(annotation) }
            addedAnnotations[ObjectIdentifier(page)] = annotations
        }
    }

    func clear() {
        guard let document else { return }
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex), let list = addedAnnotations[ObjectIdentifier(page)] else { continue }
            for annotation in list { page.removeAnnotation(annotation) }
        }
        addedAnnotations.removeAll()
    }

    private static let palette: [NSColor] = [.systemBlue, .systemGreen, .systemPurple, .systemTeal, .systemPink, .systemBrown]

    private func blockAnnotations(_ structure: DocumentStructure, pageIndex: Int) -> [PDFAnnotation] {
        var result: [PDFAnnotation] = []
        for (offset, block) in structure.blocks.enumerated() {
            guard let rects = block.lineRectsByPage[pageIndex], !rects.isEmpty else { continue }
            let color = Self.palette[offset % Self.palette.count]
            for rect in rects {
                result.append(Self.boxAnnotation(rect.insetBy(dx: -1, dy: -1), stroke: color, fill: color.withAlphaComponent(0.15), lineWidth: 0.75))
            }
            if let topRect = rects.max(by: { $0.minY > $1.minY }) {
                let labelBounds = NSRect(x: topRect.minX, y: topRect.maxY + 1, width: 150, height: 9)
                result.append(Self.labelAnnotation("#\(block.id.prefix(6)) · \(block.words)p", bounds: labelBounds, color: color))
            }
        }
        return result
    }

    private func headingAnnotations(_ structure: DocumentStructure, pageIndex: Int) -> [PDFAnnotation] {
        structure.headings.filter { $0.pageIndex == pageIndex }.map {
            Self.boxAnnotation($0.rect.insetBy(dx: -2, dy: -1), stroke: .systemOrange, fill: nil, lineWidth: 1.5)
        }
    }

    private func exhibitAnnotations(_ structure: DocumentStructure, pageIndex: Int) -> [PDFAnnotation] {
        let labels = structure.exhibits.filter { $0.page == pageIndex }.map(\.label)
        guard !labels.isEmpty, let page = document?.page(at: pageIndex) else { return [] }
        let pageRect = page.bounds(for: .mediaBox)
        let bounds = NSRect(x: pageRect.minX + 4, y: pageRect.maxY - 14, width: 220, height: 10)
        return [Self.labelAnnotation("Exhibit: \(labels.joined(separator: ", "))", bounds: bounds, color: .systemOrange)]
    }

    private func removedLineAnnotations(_ structure: DocumentStructure, pageIndex: Int) -> [PDFAnnotation] {
        guard let rects = structure.removedHeaderFooterLines[pageIndex] else { return [] }
        return rects.map { rect in
            let annotation = PDFAnnotation(bounds: rect.insetBy(dx: -1, dy: -1), forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: rect.minX, y: rect.midY)
            annotation.endPoint = CGPoint(x: rect.maxX, y: rect.midY)
            annotation.color = NSColor.systemRed.withAlphaComponent(0.85)
            let border = PDFBorder()
            border.lineWidth = 1.5
            annotation.border = border
            return annotation
        }
    }

    private static func boxAnnotation(_ rect: NSRect, stroke: NSColor, fill: NSColor?, lineWidth: CGFloat) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        annotation.color = stroke
        if let fill { annotation.interiorColor = fill }
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        return annotation
    }

    private static func labelAnnotation(_ text: String, bounds: NSRect, color: NSColor) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = NSFont.systemFont(ofSize: 6)
        annotation.fontColor = color
        annotation.color = .clear
        return annotation
    }
}
