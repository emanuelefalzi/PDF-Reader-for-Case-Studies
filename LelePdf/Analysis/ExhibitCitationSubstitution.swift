import Foundation

/// Replaces, in a block's text, citations of Exhibit/Figure/Table with
/// `[Exhibit 5, p. 19]` (SPEC §7.5 Input, last point): looks for patterns like
/// "Exhibit 5", "Figure 3", "Table 2" (case-insensitive, optionally followed
/// by a letter such as "5A"), and replaces them using the page of the
/// `ExhibitRef` that shares the same type+number. Citations with no match are
/// left intact (leave unmatched citations alone rather than inventing a
/// page). Pure, no dependency on PDFKit.
enum ExhibitCitationSubstitution {
    private static let citationRegex = try! NSRegularExpression(
        pattern: #"\b(Exhibit|Figure|Table)\s+(\d+)([A-Za-z])?\b"#,
        options: [.caseInsensitive]
    )

    static func substitute(in text: String, exhibits: [ExhibitRef]) -> String {
        guard !exhibits.isEmpty, !text.isEmpty else { return text }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = citationRegex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        let pageByKey = lookup(exhibits: exhibits)
        var result = ""
        var lastEnd = 0
        for match in matches {
            guard let key = key(for: match, in: nsText), let page = pageByKey[key] else { continue }
            let matchRange = match.range
            result += nsText.substring(with: NSRange(location: lastEnd, length: matchRange.location - lastEnd))
            result += "[\(nsText.substring(with: matchRange)), p. \(page + 1)]"
            lastEnd = matchRange.location + matchRange.length
        }
        result += nsText.substring(with: NSRange(location: lastEnd, length: nsText.length - lastEnd))
        return result
    }

    /// Type+number (without the letter) → page (0-based, like `ExhibitRef`),
    /// the first one found if several Exhibits share the same number.
    private static func lookup(exhibits: [ExhibitRef]) -> [String: Int] {
        var map: [String: Int] = [:]
        for exhibit in exhibits {
            guard let parsed = parse(exhibit.label) else { continue }
            let mapKey = "\(parsed.kind)|\(parsed.number)"
            if map[mapKey] == nil { map[mapKey] = exhibit.page }
        }
        return map
    }

    private static func key(for match: NSTextCheckingResult, in nsText: NSString) -> String? {
        guard let parsed = parse(match: match, in: nsText) else { return nil }
        return "\(parsed.kind)|\(parsed.number)"
    }

    private static func parse(_ label: String) -> (kind: String, number: Int)? {
        let ns = label as NSString
        guard let match = citationRegex.firstMatch(in: label, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return parse(match: match, in: ns)
    }

    private static func parse(match: NSTextCheckingResult, in nsText: NSString) -> (kind: String, number: Int)? {
        let kindRange = match.range(at: 1)
        let numberRange = match.range(at: 2)
        guard kindRange.location != NSNotFound, numberRange.location != NSNotFound,
              let number = Int(nsText.substring(with: numberRange)) else { return nil }
        return (nsText.substring(with: kindRange).lowercased(), number)
    }
}
