import AppKit
import Foundation
import Testing
@testable import LelePdf

@Suite("Review M7 · selection, editor and contents")
struct ReviewM7PureTests {
    private func block(_ id: String, text: String, originalStart: Int) -> TextBlock {
        TextBlock(
            id: id, sectionPath: [], pageStart: 0, pageEnd: 0,
            cleanText: text, textHash: id, words: 1,
            spans: [BlockPageSpan(
                page: 0, cleanStart: 0, cleanLength: text.count,
                charMap: Array(originalStart ..< originalStart + text.count)
            )],
            lineRectsByPage: [:]
        )
    }

    @Test("a selection on the second block of the same page is not attributed to the first")
    @MainActor
    func selectionFindsActualBlockOnPage() throws {
        let blocks = [
            block("first", text: "abcde", originalStart: 0),
            block("second", text: "vwxyz", originalStart: 10),
        ]

        let result = try #require(ManualSelectionResolver.resolve(
            page: 0, originalRange: NSRange(location: 11, length: 3), blocks: blocks
        ))
        #expect(result.blockId == "second")
        #expect(result.cleanRange == NSRange(location: 1, length: 3))
        #expect(result.text == "wxy")
    }

    @Test("the resolved text uses Character coordinates even with emoji")
    @MainActor
    func selectionExtractsComposedCharacter() throws {
        let unicode = block("unicode", text: "A😀BC", originalStart: 0)
        let result = try #require(ManualSelectionResolver.resolve(
            page: 0, originalRange: NSRange(location: 1, length: 1), blocks: [unicode]
        ))
        #expect(result.text == "😀")
    }

    @Test("marker round trip for all kinds, including table cells")
    func everyRewriteKindKeepsMarkers() {
        let items = [
            RewriteItem(kind: .summary, text: "{{m1|Sommario}}"),
            RewriteItem(kind: .definition, text: "{{m2|Definizione}}"),
            RewriteItem(kind: .bullets, items: ["Voce {{m3|segnata}}"]),
            RewriteItem(kind: .steps, items: ["Passo {{m4|segnato}}"]),
            RewriteItem(kind: .table, columns: ["A", "B"], rows: [["{{m5|cella uno}}", "cella {{m6|due}}"]]),
            RewriteItem(kind: .callout, text: "{{m7|Nota}}"),
            RewriteItem(kind: .paragraph, text: "{{m8|Paragrafo}}"),
        ]

        let built = RewriteEditText.render(items: items)
        let parsed = RewriteEditText.parse(text: built.text, spans: built.spans, originalItems: items)
        #expect(parsed == items)
    }

    @Test("renaming and changing the level of an automatic entry keep the tombstone on regeneration")
    func editedAutomaticTocEntryDoesNotReturn() throws {
        var entries = [TocEntryRecord(id: "gen-0", title: "Titolo automatico", level: 1, page: 2)]
        ManualToc.changeLevel(id: "gen-0", to: 3, entries: &entries)
        let visibleID = try #require(ManualToc.visible(entries).first?.id)
        ManualToc.rename(id: visibleID, to: "Titolo corretto", entries: &entries)

        let regenerated = ManualToc.merge(
            manual: entries.filter { $0.origin == .manual },
            newAuto: [TocEntryRecord(id: "gen-0", title: "Titolo automatico", level: 1, page: 2)]
        )
        let visible = ManualToc.visible(regenerated)
        #expect(visible.count == 1)
        #expect(visible.first?.title == "Titolo corretto")
        #expect(visible.first?.level == 3)
    }

    @Test("a manual level-1 contents entry drives the chapter scope, breadcrumb and block label")
    func manualTocFeedsDownstreamConsumers() {
        let toc = [
            TocEntry(id: "manual-1", title: "Capitolo manuale", level: 1, page: 2, origin: .manual),
            TocEntry(id: "manual-2", title: "Sottosezione", level: 2, page: 3, origin: .manual),
            TocEntry(id: "manual-2b", title: "Dettaglio", level: 3, page: 4, origin: .manual),
            TocEntry(id: "manual-3", title: "Capitolo seguente", level: 1, page: 6, origin: .manual),
        ]
        let blocks = [
            block("before", text: "a", originalStart: 0),
            TextBlock(id: "inside", sectionPath: [], pageStart: 4, pageEnd: 4, cleanText: "b", textHash: "inside", words: 1, spans: [], lineRectsByPage: [:]),
        ]

        #expect(TocNavigation.chapterPageRange(entries: toc, page: 4, pageCount: 10) == (2 ... 5))
        #expect(TocNavigation.breadcrumb(entries: toc, page: 4) == "Capitolo manuale › Sottosezione › Dettaglio")
        #expect(BlockLabeling.humanLabel(blockId: "inside", blocks: blocks, level1TocEntries: toc.filter { $0.level == 1 }) == "1.1")
    }
}
