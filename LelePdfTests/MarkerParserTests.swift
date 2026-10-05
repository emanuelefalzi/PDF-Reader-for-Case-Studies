import Testing
@testable import LelePdf

/// `MarkerParser` (SPEC §7.8 "Streaming parser", M4 point 7): pure logic, no
/// process, safe to run in parallel with any other test. Each test feeds the
/// chunks one at a time with `feed`, then closes with `finish`, and checks that
/// the resulting events are identical to those obtained by feeding the whole
/// text in a single chunk (the parser's central invariant: the cut point must
/// not change the result).
@Suite("MarkerParser")
struct MarkerParserTests {
    /// Feeds the text one character at a time (the most hostile cut possible
    /// for a multi-character marker) and collects the events.
    private func parseCharByChar(_ text: String) -> [ChatMarkerEvent] {
        let parser = MarkerParser()
        var events: [ChatMarkerEvent] = []
        for char in text {
            events += parser.feed(String(char))
        }
        events += parser.finish()
        return events
    }

    /// Feeds the text in a single chunk: the reference result.
    private func parseWhole(_ text: String) -> [ChatMarkerEvent] {
        let parser = MarkerParser()
        var events = parser.feed(text)
        events += parser.finish()
        return events
    }

    /// Concatenates the consecutive plain text of a list of events, so
    /// comparisons do not depend on how the parser split the plain-text pieces
    /// among themselves (only the order/content of the markers and of the text
    /// as a whole matter).
    private func flattenedText(_ events: [ChatMarkerEvent]) -> String {
        events.reduce(into: "") { acc, event in
            switch event {
            case .text(let text, _): acc += text
            case .citation(let label, _, _): acc += label
            }
        }
    }

    @Test("plain text without markers, in a single chunk")
    func plainTextNoMarkers() {
        let events = parseWhole("Nessun marcatore qui dentro.")
        #expect(events == [.text("Nessun marcatore qui dentro.", external: false)])
    }

    @Test("[p. N] recognized even when cut character by character")
    func singlePageCitationSplitEveryCharacter() {
        // Plain text is necessarily fragmented differently depending on the
        // cut point (feeding one chunk emits all the safe text at once, feeding
        // one character at a time produces many one-character events): it makes
        // no sense to require the two event lists to be identical, only that
        // they reconstruct the same text and recognize the same citation.
        let text = "Vedi [p. 12] per i dettagli."
        let whole = parseWhole(text)
        let split = parseCharByChar(text)
        #expect(flattenedText(whole) == text)
        #expect(flattenedText(split) == text)
        #expect(whole.contains(.citation(label: "[p. 12]", page: 12, external: false)))
        #expect(split.contains(.citation(label: "[p. 12]", page: 12, external: false)))
    }

    @Test("[pp. N–M] keeps the first page, full label")
    func pageRangeCitationKeepsFirstPage() {
        let events = parseWhole("Come mostrato in [pp. 3–5] del documento.")
        #expect(events.contains(.citation(label: "[pp. 3–5]", page: 3, external: false)))
    }

    @Test("[pp. N–M] with an ASCII hyphen, not just an en dash")
    func pageRangeCitationWithAsciiHyphen() {
        let events = parseWhole("Vedi [pp. 3-5].")
        #expect(events.contains(.citation(label: "[pp. 3-5]", page: 3, external: false)))
    }

    @Test("[p. N, M] keeps the first page, full label")
    func multiplePagesCitationKeepsFirstPage() {
        let events = parseWhole("Confronta [p. 7, 9] con l'introduzione.")
        #expect(events.contains(.citation(label: "[p. 7, 9]", page: 7, external: false)))
    }

    @Test("<fuori>…</fuori> marks the inner text as external")
    func externalSpanMarksTextExternal() {
        let events = parseWhole("Testo normale. <fuori>Questo viene da fuori.</fuori> Ancora normale.")
        #expect(events.contains(.text("Questo viene da fuori.", external: true)))
        #expect(events.contains(.text("Testo normale. ", external: false)))
        #expect(events.contains(.text(" Ancora normale.", external: false)))
    }

    @Test("<fuori>…</fuori> split into tiny chunks, at every cut point")
    func externalSpanSplitAtEveryBoundary() {
        let text = "Prima <fuori>dentro</fuori> dopo"
        // The <fuori>/</fuori> tags are structural markers, not text: the
        // parser consumes them and never puts them back into a .text event
        // (that is exactly their purpose). The expected reconstructed text is
        // therefore the one without the tags, not the original text.
        let strippedText = "Prima dentro dopo"
        for cut in 0...text.count {
            let index = text.index(text.startIndex, offsetBy: cut)
            let firstHalf = String(text[..<index])
            let secondHalf = String(text[index...])
            let parser = MarkerParser()
            var events = parser.feed(firstHalf)
            events += parser.feed(secondHalf)
            events += parser.finish()
            #expect(flattenedText(events) == strippedText, "cut at character \(cut) altered the reconstructed text")
            // If the cut falls inside "dentro" itself, the parser legitimately
            // emits it as two consecutive events (both external): only the
            // external-marked text is concatenated, instead of requiring a
            // single indivisible event.
            let externalText = events.reduce(into: "") { acc, event in
                if case .text(let fragment, external: true) = event { acc += fragment }
            }
            #expect(externalText == "dentro", "cut at character \(cut) did not correctly recognize the external span")
        }
    }

    @Test("page citation split at every possible cut point")
    func citationSplitAtEveryBoundary() {
        let text = "Vedi [p. 42] qui."
        for cut in 0...text.count {
            let index = text.index(text.startIndex, offsetBy: cut)
            let firstHalf = String(text[..<index])
            let secondHalf = String(text[index...])
            let parser = MarkerParser()
            var events = parser.feed(firstHalf)
            events += parser.feed(secondHalf)
            events += parser.finish()
            #expect(flattenedText(events) == text, "cut at character \(cut) altered the reconstructed text")
            #expect(events.contains(.citation(label: "[p. 42]", page: 42, external: false)), "cut at character \(cut) did not recognize the citation")
        }
    }

    @Test("a trailing [ with nothing after it stays buffered until more text arrives, then is flushed as plain text")
    func danglingBracketAtEndFlushedAsPlainText() {
        let parser = MarkerParser()
        let firstBatch = parser.feed("Frase che finisce con [")
        // A lone "[" may be the start of a citation: not emitted yet.
        #expect(!firstBatch.contains { if case .text(let t, _) = $0 { return t.hasSuffix("[") }; return false })
        let finalBatch = parser.finish()
        #expect(finalBatch == [.text("[", external: false)])
    }

    @Test("<fuori> without a closing tag: everything that follows stays external until finish()")
    func unclosedExternalSpanStaysExternalUntilFinish() {
        let parser = MarkerParser()
        // No incomplete marker is pending after "chiuso": the text after
        // <fuori> is already emitted by feed(), not only by finish().
        var events = parser.feed("Prima <fuori>dentro e mai chiuso")
        events += parser.finish()
        #expect(events.contains(.text("dentro e mai chiuso", external: true)))
    }

    @Test("several citation markers in the same chunk, in order")
    func multipleCitationsInSameChunk() {
        let events = parseWhole("Vedi [p. 1] e poi [p. 2] e infine [p. 3].")
        let pages = events.compactMap { event -> Int? in
            if case .citation(_, let page, _) = event { return page }
            return nil
        }
        #expect(pages == [1, 2, 3])
    }

    @Test("a citation inside an external span stays marked as external")
    func citationInsideExternalSpanIsExternal() {
        let events = parseWhole("<fuori>Fonte esterna [p. 99] non dal PDF.</fuori>")
        #expect(events.contains(.citation(label: "[p. 99]", page: 99, external: true)))
    }
}
