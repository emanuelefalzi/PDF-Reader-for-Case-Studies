import Foundation
import Testing
@testable import LelePdf

/// Additional tests from the M9 cross-review (SPEC §7.8.1). The MANDATORY
/// safety test (`ChatRealTests.searchModeDeniesOutsideReads`) never produces
/// a result inside the XCTest host; the review attempted it outside
/// `xcodebuild` with 2 real questions (the maximum budget allowed), without
/// managing to observe a real attempt to read outside the folder (the model
/// always refused before emitting a `tool_use` Read). That is inconclusive,
/// so `ChatSearchPolicy.isEnabled` stays `false`. These tests block a future
/// re-enabling "by mistake" (not deliberate) and add a static guard on the
/// declared technical confinement (`allowedTools`), since the one thing NOT
/// verified live is precisely whether that confinement holds against a real
/// attempt.
@Suite("M9 cross-review")
struct ReviewM9Tests {
    private let template = """
    T={{DOCUMENT_TITLE}}
    I={{TOC}}
    G={{GLOSSARY}}
    M={{MEMORY}}
    S={{SCOPE_DESCRIPTION}}
    R={{SEARCH_INSTRUCTIONS}}
    C={{DOCUMENT_CONTENT}}
    """

    private func snapshot(pageLength: Int = 20, current: Int = 4) -> ChatDocumentSnapshot {
        ChatDocumentSnapshot(
            title: "Documento",
            fingerprint: "review-m9",
            pageTexts: (0 ..< 12).map { "TESTO-PAGINA-\($0 + 1) " + String(repeating: "x", count: pageLength) },
            toc: [ChatTOCEntry(title: "Capitolo 1", level: 1, page: 0)],
            glossary: [],
            analyzedSummaries: [],
            currentPageIndex: current,
            visiblePageRange: 4...5
        )
    }

    /// Not a duplicate of `ChatContextTests.searchDisabledByDefaultThrows`:
    /// that test verifies the behavior of the flag when off; this one
    /// documents EXPLICITLY why it must stay off after the cross-review of
    /// 2026-09-16. The safety test attempted with 2 real questions outside
    /// `xcodebuild` did not observe a real attempt to read outside the folder
    /// (no `tool_use` Read emitted in either run, even with a minimal system
    /// prompt designed not to influence the model), so the technical
    /// confinement (`--allowedTools`/`--permission-mode dontAsk`) remains NOT
    /// confirmed. If this test is ever removed or changed to re-enable
    /// search, it must be a deliberate choice after a real observation of a
    /// denied attempt, not a typo.
    @Test("search mode stays disabled: no positive observation of the technical confinement")
    func searchPolicyRemainsDisabledPendingConfirmedSandboxTest() {
        #expect(ChatSearchPolicy.isEnabled == false)
    }

    /// Static guard on the confinement declared by `ChatContextBuilder` for
    /// search mode: EVERY `--allowedTools` pattern must stay bound to RELATIVE
    /// paths inside the working folder (`./**`), never a wider pattern
    /// (`Read(**)`, an absolute path, `~`). This is exactly the property that
    /// the live test of SPEC §7.8.1 should have confirmed behaviorally (a real
    /// denied attempt); having been unable to observe it, this test at least
    /// prevents a future refactor from silently widening the pattern without
    /// anyone noticing (it would fail here).
    @Test("the allowedTools patterns of search mode stay scoped to ./** ")
    func searchModeAllowedToolsStayScopedToRelativePaths() throws {
        let previous = ChatSearchPolicy.isEnabled
        ChatSearchPolicy.isEnabled = true
        defer { ChatSearchPolicy.isEnabled = previous }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lelepdf-review-m9-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try ChatContextBuilder.build(
            snapshot: snapshot(pageLength: 34_000), scope: .wholeDocument,
            memory: nil, cacheRoot: root, template: template
        )
        guard case .search(_, let allowedTools) = plan.mode else {
            Issue.record("search mode expected with this snapshot (over 100k tokens)")
            return
        }
        #expect(!allowedTools.isEmpty)
        let scopedPattern = #/^(Read|Grep|Glob)\(\./\*\*\)$/#
        for pattern in allowedTools {
            #expect(pattern.wholeMatch(of: scopedPattern) != nil, "pattern not scoped to ./**: \(pattern)")
        }
    }

    /// The `ChatSearchPolicy.isEnabled` flag and the 100 thousand token
    /// threshold are two INDEPENDENT conditions (SPEC §7.8.1): re-enabling the
    /// flag must not trigger search mode for a small scope, which must stay
    /// `.normal` (zero tools, no possibility of reading files) exactly as it
    /// does today. If a future change inverted this logic by mistake (e.g.
    /// search mode always triggered when the flag is on, regardless of
    /// tokens), a small scope would lose the "zero tools" guarantee that the
    /// M9 cross-review verified to be the only thing that makes the normal
    /// path safe even without the confirmed technical confinement.
    @Test("the search flag alone does not force search mode below the threshold")
    func searchPolicyFlagAloneDoesNotForceSearchModeBelowThreshold() throws {
        let previous = ChatSearchPolicy.isEnabled
        ChatSearchPolicy.isEnabled = true
        defer { ChatSearchPolicy.isEnabled = previous }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lelepdf-review-m9-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = try ChatContextBuilder.build(
            snapshot: snapshot(pageLength: 20), scope: .visiblePages,
            memory: nil, cacheRoot: root, template: template
        )
        guard case .normal = plan.mode else {
            Issue.record("a below-threshold scope must stay in normal mode even with the flag on")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: root.path), "normal mode must never write pages to disk")
    }
}
