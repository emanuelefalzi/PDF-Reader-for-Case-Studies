import Foundation
import Testing
@testable import LelePdf

@Suite("Smoke")
struct SmokeTests {
    @Test("the test target sees the LelePdf module")
    func moduleLinks() {
        let doc = PDFFileDocument(data: Data(), displayName: "prova")
        #expect(doc.displayName == "prova")
        #expect(doc.data.isEmpty)
    }
}
