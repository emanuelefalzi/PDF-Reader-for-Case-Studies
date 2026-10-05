import AppKit
import CryptoKit
@preconcurrency import PDFKit

/// Reads the native annotations created by Preview (or other PDF editors)
/// and converts them into LelePdf's model. Those signed by LelePdf are
/// recognized and removed only from the in-memory copy: they will be
/// redrawn from the JSON data/overlay, avoiding any visual duplicate on
/// reopening.
@MainActor
enum PDFAnnotationImporter {
    struct Result {
        var external: [Annotation]
        var recoveredFreeAnnotations: [Annotation]
    }

    static func readAndDetachOwned(from document: PDFDocument) -> Result {
        var external: [Annotation] = []
        var recovered: [Annotation] = []
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for (ordinal, pdfAnnotation) in page.annotations.enumerated() {
                if let tag = PDFAnnotationOwnership.tag(of: pdfAnnotation) {
                    if tag.role == .freeAnnotation,
                       let model = makeModel(pdfAnnotation, page: pageIndex, ordinal: ordinal, forcedID: tag.id) {
                        recovered.append(model)
                    }
                    page.removeAnnotation(pdfAnnotation)
                } else if let model = makeModel(pdfAnnotation, page: pageIndex, ordinal: ordinal, forcedID: nil) {
                    external.append(model)
                }
            }
        }
        return Result(external: external, recoveredFreeAnnotations: recovered)
    }

    private static func makeModel(
        _ pdf: PDFAnnotation, page: Int, ordinal: Int, forcedID: String?
    ) -> Annotation? {
        guard let kind = kind(of: pdf) else { return nil }
        let stableIdentity = forcedID ?? externalIdentity(pdf, page: page, ordinal: ordinal)
        let date = pdf.modificationDate ?? Date(timeIntervalSince1970: 0)
        let borderWidth = pdf.border?.lineWidth
        let points: [AnnotationPoint]?
        if kind == .line || kind == .arrow {
            points = [AnnotationPoint(pdf.startPoint), AnnotationPoint(pdf.endPoint)]
        } else {
            points = nil
        }
        // Preview-style highlighter: a highlight/underline/strikethrough
        // imported from Preview (or another editor) must be markable/
        // unmarkable like one created by LelePdf, and that requires a
        // `textRange`, which is absent from the standard PDF (only
        // `QuadPoints`/`Rect`). It is rebuilt here from the bounding box
        // with `page.selection(for rect:)` (`AnnotationTextRangeResolver`,
        // the same technique `AnnotationTextMarkupCreator` uses on the fly
        // for older data that lacks one). The per-line quads (not just the
        // bounding box) also improve redraw fidelity for an imported
        // multi-line highlight.
        var resolvedTextRange: AnnotationTextRange?
        var resolvedQuads: [AnnotationRect]?
        if kind.isTextMarkup, let page = pdf.page {
            if let range = AnnotationTextRangeResolver.range(for: pdf.bounds, on: page),
               let selection = page.selection(for: NSRange(location: range.start, length: range.length)) {
                let lines = selection.selectionsByLine()
                if !lines.isEmpty {
                    resolvedTextRange = range
                    resolvedQuads = lines.map { AnnotationRect($0.bounds(for: page)) }
                }
            }
        }
        return Annotation(
            id: forcedID ?? "pdf-" + stableIdentity,
            page: page,
            kind: kind,
            color: modelColor(pdf.color),
            fillColor: pdf.interiorColor.map(modelColor),
            lineWidth: borderWidth.map(Double.init),
            dash: pdf.border?.dashPattern?.compactMap { ($0 as? NSNumber)?.doubleValue },
            rect: AnnotationRect(pdf.bounds),
            textRange: resolvedTextRange,
            quads: resolvedQuads ?? (kind.isTextMarkup ? [AnnotationRect(pdf.bounds)] : nil),
            points: points,
            text: pdf.contents,
            fontSize: pdf.font.map { Double($0.pointSize) },
            font: pdf.font?.fontName,
            alignment: alignmentName(pdf.alignment),
            externalPDFIdentifier: forcedID == nil ? stableIdentity : nil,
            createdAt: date,
            updatedAt: date
        )
    }

    private static func kind(of annotation: PDFAnnotation) -> AnnotationKind? {
        guard let rawType = annotation.type else { return nil }
        // `PDFAnnotationSubtype.rawValue` includes the leading slash
        // ("/Highlight"), while `PDFAnnotation.type` returns
        // "Highlight" after reopening from disk.
        let subtype = PDFAnnotationSubtype(rawValue: rawType.hasPrefix("/") ? rawType : "/" + rawType)
        switch subtype {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeOut: return .strikeout
        case .ink: return .ink
        case .square: return .rectangle
        case .circle: return .ellipse
        case .line:
            return annotation.endLineStyle == .none ? .line : .arrow
        case .freeText: return .textbox
        case .text: return .note
        default: return nil
        }
    }

    private static func modelColor(_ color: NSColor) -> AnnotationColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return AnnotationColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }

    private static func alignmentName(_ alignment: NSTextAlignment) -> String? {
        switch alignment {
        case .left: "left"
        case .center: "center"
        case .right: "right"
        default: nil
        }
    }

    private static func externalIdentity(_ annotation: PDFAnnotation, page: Int, ordinal: Int) -> String {
        if let name = annotation.value(forAnnotationKey: .name) as? String, !name.isEmpty {
            return digest("name|\(name)")
        }
        let color = modelColor(annotation.color)
        let rect = annotation.bounds
        let value = [
            String(page), String(ordinal), annotation.type ?? "", annotation.contents ?? "",
            "\(rect.origin.x),\(rect.origin.y),\(rect.width),\(rect.height)",
            "\(color.red),\(color.green),\(color.blue),\(color.alpha)",
        ].joined(separator: "|")
        return digest(value)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
