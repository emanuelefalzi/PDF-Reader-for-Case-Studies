import Foundation
import Testing
@testable import LelePdf

/// Pure cleaning (SPEC §7.2), on synthetic lines: ligatures, superscript
/// digits, spaced-out letters, words broken at the end of a line.
@Suite("Pipeline · cleaning")
struct TextCleaningTests {
    @Test("fi ligature expanded, original indices preserved")
    func ligatureExpansion() {
        let line = PipelineFixtures.extractedLine(text: "\u{FB01}le", location: 10, rect: .zero)
        let result = TextCleaner.indexedText(for: line)
        #expect(result.string == "file")
        #expect(result.map(\.orig) == [10, 10, 11, 12])
    }

    @Test("superscript digits removed from the clean text")
    func superscriptRemoval() {
        let text = "returns.20"
        let line = PipelineFixtures.extractedLine(
            text: text, location: 100, rect: .zero,
            superscriptRanges: [CharRange(location: 108, length: 2)]
        )
        let result = TextCleaner.indexedText(for: line)
        #expect(result.string == "returns.")
    }

    @Test("spaced-out letters recompacted (sequence of at least 3)")
    func spacedLettersRecompacted() {
        let indexed = PipelineFixtures.indexedText("T H E F U T U R E")
        let result = TextCleaner.recompactSpacedLetters(indexed)
        #expect(result.string == "THEFUTURE")
    }

    @Test("genuine one-letter words left untouched when isolated")
    func isolatedSingleLetterWordsUntouched() {
        let indexed = PipelineFixtures.indexedText("I said a lot")
        let result = TextCleaner.recompactSpacedLetters(indexed)
        #expect(result.string == "I said a lot")
    }

    @Test("run of spaced-out letters followed by a normal word")
    func spacedRunFollowedByWord() {
        let indexed = PipelineFixtures.indexedText("A B C D word")
        let result = TextCleaner.recompactSpacedLetters(indexed)
        #expect(result.string == "ABCD word")
    }

    @Test("word broken at the end of a line is rejoined (connec- / tivity)")
    func hyphenationJoin() {
        let line0 = PipelineFixtures.cleanLine(lineIndex: 0, text: "connec-", y: 700)
        let line1 = PipelineFixtures.cleanLine(lineIndex: 1, text: "tivity and growth", y: 680)
        let page = CleanPage(pageIndex: 0, pageRect: PageRect(x: 0, y: 0, width: 600, height: 800), lines: [line0, line1])

        let result = HyphenationJoiner.apply(to: [page])[0]
        #expect(result.lines[0].text.string == "connectivity and growth")
        #expect(result.lines[0].joinedWithNext == true)
        #expect(result.lines[1].consumedByPrevious == true)
        #expect(result.contentLines.count == 1)
        #expect(result.contentLines[0].text.string.contains("connectivity"))
        #expect(!result.contentLines[0].text.string.contains("connec-"))
    }

    @Test("no join if the next line starts with an uppercase letter")
    func noJoinWhenNextStartsUppercase() {
        let line0 = PipelineFixtures.cleanLine(lineIndex: 0, text: "end of a list-", y: 700)
        let line1 = PipelineFixtures.cleanLine(lineIndex: 1, text: "Next sentence starts here", y: 680)
        let page = CleanPage(pageIndex: 0, pageRect: PageRect(x: 0, y: 0, width: 600, height: 800), lines: [line0, line1])

        let result = HyphenationJoiner.apply(to: [page])[0]
        #expect(result.lines[0].joinedWithNext == false)
        #expect(result.contentLines.count == 2)
    }
}
