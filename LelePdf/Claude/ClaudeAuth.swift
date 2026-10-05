import Foundation
import Observation

/// State of the connection to Claude (SPEC §5.11 "Claude status", §5.12).
enum ClaudeAuthState: Sendable, Equatable {
    case notFound
    case notLoggedIn
    case loggedIn(email: String?, plan: String?)
    case error(String)

    var isUsable: Bool {
        if case .loggedIn = self { return true }
        return false
    }
}

/// Reads and interprets `claude auth status` (SPEC §5.11, §4: JSON
/// `{loggedIn, authMethod, email, subscriptionType}`).
enum ClaudeAuth {
    static func checkStatus(cliPath: String) async -> ClaudeAuthState {
        let result = await OneShotProcess.run(
            executable: cliPath, arguments: ["auth", "status"],
            environment: ClaudeEnvironment.baseEnvironment(cliPath: cliPath),
            currentDirectory: ClaudeEnvironment.cacheDirectory(), timeout: 15
        )
        return parse(result)
    }

    static func parse(_ result: ProcessRunResult) -> ClaudeAuthState {
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if ClaudeErrorMapper.isNotLoggedIn(result.stdout + result.stderr) { return .notLoggedIn }
            return .error(String(localized: "Invalid response from \u{201c}claude auth status\u{201d}."))
        }
        let loggedIn = json["loggedIn"] as? Bool ?? false
        guard loggedIn else { return .notLoggedIn }
        return .loggedIn(email: json["email"] as? String, plan: json["subscriptionType"] as? String)
    }
}

/// App-level observable state (SPEC §5.11): refreshed at launch and on
/// request ("Verify"). A single shared instance: Claude's status does not
/// depend on the window.
@MainActor
@Observable
final class ClaudeStatusModel {
    static let shared = ClaudeStatusModel()

    private(set) var state: ClaudeAuthState = .notFound
    private(set) var isRefreshing = false

    private init() {}

    @discardableResult
    func refresh() async -> ClaudeAuthState {
        isRefreshing = true
        defer { isRefreshing = false }
        switch await ClaudeCLILocator.shared.info() {
        case .failure:
            state = .notFound
        case .success(let info):
            guard info.isUsable else {
                state = .error(String(localized: "The Claude CLI does not support the required flags: \(info.missingFlags.joined(separator: ", "))."))
                return state
            }
            state = await ClaudeAuth.checkStatus(cliPath: info.path)
        }
        return state
    }
}
