import Foundation

/// Word count (SPEC §5.14 "how many words the block and each rewrite has"):
/// pure, testable on its own. Same definition of "word" already implicit in
/// `TextBlock.words`/SPEC §7.3 (whitespace separators), exposed here to also
/// count a rewrite text generated on the fly (Summary Lab, new attempt).
enum WordCount {
    static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
