import Foundation

/// PDF without selectable text (SPEC §5.2): fewer than 30 characters on
/// more than 80% of the pages. Pure: it takes only the lengths of `page.string`.
enum TextlessDetector {
    static func isTextless(pageTextLengths: [Int]) -> Bool {
        guard !pageTextLengths.isEmpty else { return false }
        let shortCount = pageTextLengths.filter { $0 < 30 }.count
        return Double(shortCount) / Double(pageTextLengths.count) > 0.80
    }
}
