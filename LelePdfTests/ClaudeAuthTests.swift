import Foundation
import Testing
@testable import LelePdf

/// `ClaudeAuth.parse` (SPEC §5.11, §4): pure function, no process involved,
/// safe to run in parallel with any other test.
/// `ClaudeAuth.checkStatus`/`ClaudeStatusModel` (which really invoke the
/// CLI) are covered by the integration tests at the bottom, serialized like
/// the rest of the Claude module.
@Suite("ClaudeAuth")
struct ClaudeAuthTests {
    private func result(stdout: String, stderr: String = "", status: Int32 = 0) -> ProcessRunResult {
        ProcessRunResult(status: status, stdout: stdout, stderr: stderr, timedOut: false)
    }

    @Test("loggedIn true with email and plan")
    func parsesLoggedIn() {
        let json = #"{"loggedIn":true,"authMethod":"claude.ai","email":"lele@example.com","subscriptionType":"max"}"#
        let state = ClaudeAuth.parse(result(stdout: json))
        #expect(state == .loggedIn(email: "lele@example.com", plan: "max"))
        #expect(state.isUsable)
    }

    @Test("loggedIn false becomes notLoggedIn")
    func parsesLoggedOut() {
        let json = #"{"loggedIn":false}"#
        let state = ClaudeAuth.parse(result(stdout: json, status: 1))
        #expect(state == .notLoggedIn)
        #expect(!state.isUsable)
    }

    @Test("non-JSON stdout with a recognized login message becomes notLoggedIn")
    func nonJsonWithLoginMessage() {
        let state = ClaudeAuth.parse(result(stdout: "", stderr: "Please run /login\n", status: 1))
        #expect(state == .notLoggedIn)
    }

    @Test("non-JSON stdout with no recognized message becomes error")
    func nonJsonUnrecognized() {
        let state = ClaudeAuth.parse(result(stdout: "qualcosa di inatteso", status: 1))
        guard case .error = state else {
            Issue.record("expected .error, found \(state)")
            return
        }
    }

    @Test("real checkStatus (fake CLI): loggedIn true")
    func checkStatusLoggedIn() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path, "FAKE_CLAUDE_MODE": nil]) {
            let state = await ClaudeAuth.checkStatus(cliPath: FakeClaudeLocator.path)
            #expect(state.isUsable)
        }
    }

    @Test("real checkStatus (fake CLI): not_logged_in")
    func checkStatusNotLoggedIn() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path, "FAKE_CLAUDE_MODE": "not_logged_in"]) {
            let state = await ClaudeAuth.checkStatus(cliPath: FakeClaudeLocator.path)
            #expect(state == .notLoggedIn)
        }
    }

    @Test("ClaudeStatusModel.refresh() updates the observable state")
    func statusModelRefresh() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path, "FAKE_CLAUDE_MODE": nil]) {
            let state = await ClaudeStatusModel.shared.refresh()
            #expect(state.isUsable)
            let stillRefreshing = await ClaudeStatusModel.shared.isRefreshing
            #expect(!stillRefreshing)
        }
    }
}
