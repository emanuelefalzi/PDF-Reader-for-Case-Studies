import Foundation

/// Turns resolved segments (`AnalysisController.ResolvedSegment`, with the
/// `{{mX|words}}` markers already resolved upstream) into plain text plus
/// marked ranges (SPEC §5.6 "Marked terms in the rewritten text"). Pure: no
/// dependency on `NSAttributedString`/AppKit, so it can be tested on its own
/// ("text attribute building"); `MarkedTextView` uses it to build the real
/// `NSAttributedString`.
enum MarkedTextBuilder {
    struct MarkedRange: Equatable {
        var range: NSRange
        var markId: String? = nil
        var termId: String
        var type: MarkType
    }

    struct Built: Equatable {
        var text: String
        var marks: [MarkedRange]
    }

    static func build(_ segments: [AnalysisController.ResolvedSegment]) -> Built {
        var text = ""
        var marks: [MarkedRange] = []
        for segment in segments {
            switch segment {
            case .plain(let string):
                text += string
            case .marked(let string, let markId, let termId, let type):
                let start = (text as NSString).length
                text += string
                let length = (string as NSString).length
                marks.append(MarkedRange(range: NSRange(location: start, length: length), markId: markId, termId: termId, type: type))
            }
        }
        return Built(text: text, marks: marks)
    }

    /// Concatenates several lines of segments (bulleted/numbered lists,
    /// table rows) into a single text with a separator, mapping the ranges
    /// into the coordinate system of the joined text.
    static func build(lines: [[AnalysisController.ResolvedSegment]], separator: String = "\n") -> Built {
        var text = ""
        var marks: [MarkedRange] = []
        for (index, line) in lines.enumerated() {
            if index > 0 { text += separator }
            let base = (text as NSString).length
            let built = build(line)
            text += built.text
            marks.append(contentsOf: built.marks.map {
                MarkedRange(
                    range: NSRange(location: $0.range.location + base, length: $0.range.length),
                    markId: $0.markId,
                    termId: $0.termId,
                    type: $0.type
                )
            })
        }
        return Built(text: text, marks: marks)
    }
}
