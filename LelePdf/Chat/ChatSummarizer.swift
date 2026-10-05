import Foundation

enum ChatPreferences {
    static let budgetDefaultsKey = "chatContextBudget"
    static let modelDefaultsKey = "chatModel"
    static var defaultStore: UserDefaults { AppRuntime.defaults }

    static var budget: Int {
        if let raw = ProcessInfo.processInfo.environment["LELEPDF_CHAT_BUDGET"], let value = Int(raw), value > 0 {
            return value
        }
        let saved = defaultStore.integer(forKey: budgetDefaultsKey)
        return saved > 0 ? saved : 80_000
    }

    static var model: ClaudeModel {
        guard let raw = defaultStore.string(forKey: modelDefaultsKey),
              let model = ClaudeModel(rawValue: raw) else { return .sonnet }
        return model
    }
}

enum ChatTranscript {
    static func render(_ messages: [ChatMessage]) -> String {
        messages.compactMap { message in
            switch message.role {
            case .user: return "User: \(message.rawText)"
            case .assistant: return "Assistant: \(message.rawText)"
            case .note, .divider: return nil
            }
        }.joined(separator: "\n\n")
    }

    static func fallbackSummary(_ messages: [ChatMessage]) -> String {
        String(render(messages).suffix(12_000))
    }
}

enum ChatSummarizer {
    static func summarize(_ messages: [ChatMessage], model: ClaudeModel = .sonnet) async -> String? {
        guard let systemPrompt = ClaudeResources.promptText(named: "chat-summary") else { return nil }
        guard case .success(let info) = await ClaudeCLILocator.shared.info(), info.isUsable else { return nil }
        let transcript = ChatTranscript.render(messages)
        guard !transcript.isEmpty else { return nil }
        let result = await OneShotProcess.run(
            executable: info.path,
            arguments: [
                "-p", transcript,
                "--model", model.rawValue,
                "--safe-mode", "--tools", "",
                "--strict-mcp-config", "--no-session-persistence",
                "--system-prompt", systemPrompt,
                "--output-format", "json",
            ],
            environment: ClaudeEnvironment.baseEnvironment(cliPath: info.path),
            currentDirectory: ClaudeEnvironment.cacheDirectory(),
            timeout: 120
        )
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["is_error"] as? Bool != true,
              let text = json["result"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
