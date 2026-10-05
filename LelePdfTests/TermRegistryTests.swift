import Foundation
import Testing
@testable import LelePdf

/// Term registry (SPEC §7.5 point 1, M5a deliverable 4).
@Suite("TermRegistry")
struct TermRegistryTests {
    @Test("same normalized term as an existing one: reuses its termId, ignoring the proposed termId")
    func reusesExistingTermIdOnNormalizedMatch() {
        let terms = ["t1": TermRecord(term: "Food and Drug Administration", type: .circle, firstBlockId: "b1")]
        let resolution = TermRegistry.resolve(term: "  FOOD   and Drug Administration ", proposedTermId: "t99", in: terms)
        #expect(resolution.termId == "t1")
        #expect(!resolution.isNew)
    }

    @Test("termId proposed by Claude already exists in the glossary: reused")
    func reusesProposedTermIdWhenPresent() {
        let terms = ["t7": TermRecord(term: "FDA", type: .circle, firstBlockId: "b1")]
        let resolution = TermRegistry.resolve(term: "the FDA", proposedTermId: "t7", in: terms)
        // the normalized "the FDA" does not match "FDA": falls through to the second criterion.
        #expect(resolution.termId == "t7")
        #expect(!resolution.isNew)
    }

    @Test("neither term nor termId match: new, stable, increasing termId")
    func mintsNewStableId() {
        let terms = ["t1": TermRecord(term: "A", type: .rectangle, firstBlockId: "b1"), "t3": TermRecord(term: "B", type: .rectangle, firstBlockId: "b1")]
        let resolution = TermRegistry.resolve(term: "Concetto nuovo", proposedTermId: nil, in: terms)
        #expect(resolution.termId == "t4")
        #expect(resolution.isNew)
    }

    @Test("empty registry: first id is t1")
    func firstIdInEmptyRegistry() {
        let resolution = TermRegistry.resolve(term: "Primo", proposedTermId: nil, in: [:])
        #expect(resolution.termId == "t1")
        #expect(resolution.isNew)
    }

    @Test("normalization: lowercase and consecutive spaces collapsed to one")
    func normalizeCollapsesWhitespaceAndCase() {
        #expect(TermRegistry.normalize("  FDA   spending ") == "fda spending")
    }
}
