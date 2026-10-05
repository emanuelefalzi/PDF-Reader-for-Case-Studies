import Testing
@testable import LelePdf

/// PDF without selectable text (SPEC §5.2): fewer than 30 characters in more
/// than 80% of the pages.
@Suite("Pipeline · PDF without text")
struct TextlessDetectorTests {
    @Test("most pages with little text means 'textless'")
    func mostlyEmptyPagesAreTextless() {
        let lengths = Array(repeating: 5, count: 9) + [2000]
        #expect(TextlessDetector.isTextless(pageTextLengths: lengths))
    }

    @Test("a document with normal text is not 'textless'")
    func normalDocumentIsNotTextless() {
        let lengths = Array(repeating: 2000, count: 10)
        #expect(!TextlessDetector.isTextless(pageTextLengths: lengths))
    }

    @Test("an empty document is not considered 'textless' by default")
    func emptyDocumentIsFalse() {
        #expect(!TextlessDetector.isTextless(pageTextLengths: []))
    }
}
