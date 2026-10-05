import Foundation

/// An entry cleaned up by Claude (SPEC §7.4, `toc.schema.json`). The page is
/// **1-based**, as sent in the prompt and as the schema requires
/// (`minimum: 1`): the conversion to the 0-based `TocEntry`/`TocEntryRecord`
/// happens after validation.
struct GeneratedTocEntry: Sendable, Codable, Equatable {
    var title: String
    var level: Int
    var page: Int
}

private struct TocGenerationOutput: Sendable, Codable {
    var entries: [GeneratedTocEntry]
}

/// Errors specific to contents generation: those of the Claude layer, plus a
/// response that is syntactically valid but violates the §7.4 rules (pages out
/// of range, levels outside 1-3, etc.).
enum TocGenerationError: Error, Sendable, Equatable {
    case claude(ClaudeError)
    case invalidEntries(String)

    var userMessage: String {
        switch self {
        case .claude(let error): return error.userMessage
        case .invalidEntries(let reason): return String(localized: "Invalid generated table of contents (\(reason)).")
        }
    }
}

/// Generated contents (SPEC §7.4): cleans up the `TocCandidate` candidates
/// with Claude (Sonnet model, `Prompts/toc.md` + `Schemas/toc.schema.json`) and
/// validates the result before the caller (`DocumentModel`) saves it.
enum TocGenerator {
    /// User text (SPEC §7.4 point 2): title, page count, then each candidate
    /// with its **1-based** page, level hint, provenance and the next ~20
    /// words, not the whole document.
    static func buildPrompt(title: String, pageCount: Int, candidates: [TocCandidate]) -> String {
        var lines = [
            "Document: \(title)",
            "Total pages: \(pageCount)",
            "",
            "Candidates (1-based page numbers):",
        ]
        for candidate in candidates {
            let sourceLabel = candidate.source == .heading ? "title" : "repeated running header"
            let following = candidate.followingWords.isEmpty ? "(none)" : candidate.followingWords
            lines.append("- p.\(candidate.page + 1) [suggested level \(candidate.levelHint), \(sourceLabel)]: \"\(candidate.title)\" — followed by: \(following)")
        }
        return lines.joined(separator: "\n")
    }

    /// Fails (rather than crashing) if `Resources/Prompts/toc.md` or
    /// `Resources/Schemas/toc.schema.json` is missing from the bundle (this
    /// should not happen outside tests, but SPEC says "never crash").
    static func generate(
        title: String, pageCount: Int, candidates: [TocCandidate], model: ClaudeModel = .sonnet
    ) async -> Result<BatchOutcome<[GeneratedTocEntry]>, TocGenerationError> {
        guard !candidates.isEmpty else {
            return .success(BatchOutcome(value: [], usage: ClaudeUsage(), durationMs: 0))
        }
        guard let systemPrompt = ClaudeResources.promptText(named: "toc") else {
            return .failure(.claude(.processFailed(stderrTail: "Resources/Prompts/toc.md missing from bundle")))
        }
        guard let schema = ClaudeResources.schemaText(named: "toc") else {
            return .failure(.claude(.processFailed(stderrTail: "Resources/Schemas/toc.schema.json missing from bundle")))
        }

        let prompt = buildPrompt(title: title, pageCount: pageCount, candidates: candidates)
        let request = BatchRequest(prompt: prompt, model: model, systemPrompt: systemPrompt, jsonSchema: schema)

        let outcome = await BatchRunner.shared.run(request) { data in
            try? JSONDecoder().decode(TocGenerationOutput.self, from: data)
        }

        switch outcome {
        case .failure(let error):
            return .failure(.claude(error))
        case .success(let batch):
            switch validate(batch.value.entries, pageCount: pageCount) {
            case .failure(let failure):
                return .failure(.invalidEntries(failure.reason))
            case .success(let entries):
                return .success(BatchOutcome(value: entries, usage: batch.usage, durationMs: batch.durationMs))
            }
        }
    }

    /// Textual reason for a `validate` failure (`Result.Failure` must conform
    /// to `Error`; a bare `String` is not enough).
    struct ValidationFailure: Error, Sendable, Equatable {
        let reason: String
    }

    /// SPEC: pages within the document's range, levels 1-3, non-empty titles,
    /// sorted by page.
    static func validate(_ entries: [GeneratedTocEntry], pageCount: Int) -> Result<[GeneratedTocEntry], ValidationFailure> {
        guard !entries.isEmpty else { return .failure(ValidationFailure(reason: "no entries")) }
        for entry in entries {
            guard (1...3).contains(entry.level) else { return .failure(ValidationFailure(reason: "level \(entry.level) out of 1-3")) }
            guard entry.page >= 1, entry.page <= pageCount else { return .failure(ValidationFailure(reason: "page \(entry.page) outside the document (\(pageCount) pages)")) }
            guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(ValidationFailure(reason: "empty title")) }
        }
        return .success(entries.sorted { $0.page < $1.page })
    }
}
