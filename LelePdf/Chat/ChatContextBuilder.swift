import Foundation

enum ChatSearchPolicy {
    /// Disabled for this delivery: the mandatory real test of SPEC §7.8.1
    /// could not be run all the way through in this environment (the real
    /// `claude -p` process, started directly by `ChatSession` outside
    /// `ChatController`, gets no answer for the whole idle timeout when
    /// launched from the automated test host; launching the same CLI by hand
    /// does not reproduce it, so it is not a production-code problem, but it
    /// was not possible to CONFIRM that the search confinement holds).
    /// Prudence: without confirmation, search mode stays off ("Whole PDF"
    /// still works, with a clear message above 100 thousand tokens). Set it
    /// back to `true` only after re-running
    /// `ChatRealTests.searchModeDeniesOutsideReads` with a green result (also
    /// by hand, with the real `claude`), not only with the fake CLI.
    /// `var`, not `let`: the test that builds search mode
    /// (`ChatContextTests.searchModeWritesPages`) temporarily re-enables it
    /// to exercise that code path, which stays correct and tested even
    /// though it is off by default in production.
    nonisolated(unsafe) static var isEnabled = false
}

enum ChatContextBuilder {
    static let searchThresholdTokens = 100_000

    static func estimates(for snapshot: ChatDocumentSnapshot) -> [ChatScope: Int] {
        Dictionary(uniqueKeysWithValues: ChatScope.allCases.map {
            ($0, estimate(textForRange(range(for: $0, snapshot: snapshot), snapshot: snapshot)))
        })
    }

    static func build(
        snapshot: ChatDocumentSnapshot,
        scope: ChatScope,
        memory: String?,
        cacheRoot: URL,
        template: String? = nil
    ) throws -> ChatContextPlan {
        guard !snapshot.pageTexts.isEmpty else { throw ChatContextError.noText }
        let included = range(for: scope, snapshot: snapshot)
        let text = textForRange(included, snapshot: snapshot)
        let tokens = estimate(text)
        let searchMode = tokens > searchThresholdTokens
        if searchMode, !ChatSearchPolicy.isEnabled { throw ChatContextError.searchDisabled }

        let promptTemplate = template ?? ClaudeResources.promptText(named: "chat")
        guard var prompt = promptTemplate else { throw ChatContextError.promptMissing }

        let toc = snapshot.toc.isEmpty ? "Table of contents not available." : snapshot.toc.map {
            "\(String(repeating: "  ", count: max(0, $0.level - 1)))- \($0.title) [p. \($0.page + 1)]"
        }.joined(separator: "\n")
        let glossary = snapshot.glossary.isEmpty ? "Glossary not available." : snapshot.glossary.joined(separator: "\n")
        let memoryText = memory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeMemory = memoryText?.isEmpty == false ? memoryText! : "None: this is a new conversation."
        let scopeDescription = "\(scope.label): pages \(included.lowerBound + 1)\u{2013}\(included.upperBound + 1)."

        let mode: ChatProcessMode
        let content: String
        let searchInstructions: String
        if searchMode {
            let pagesDirectory = try writeSearchPages(snapshot: snapshot, cacheRoot: cacheRoot)
            mode = .search(
                workingDirectory: pagesDirectory,
                allowedTools: ["Read(./**)", "Grep(./**)", "Glob(./**)"]
            )
            let summaries = snapshot.analyzedSummaries.isEmpty
                ? "No block analyzed yet."
                : snapshot.analyzedSummaries.joined(separator: "\n\n")
            content = "Summaries of the analyzed blocks:\n\(summaries)"
            searchInstructions = """
            The full text is in the `p-NNNN.txt` files of the current folder. Use only Read, Grep and Glob on relative `./**` paths. Search the relevant pages before answering. Never try to read absolute paths, `~`, `..` or files outside the current folder.
            """
        } else {
            mode = .normal
            content = text
            searchInstructions = "The scope's text is included below; do not use tools."
        }

        let replacements = [
            "{{DOCUMENT_TITLE}}": snapshot.title,
            "{{TOC}}": toc,
            "{{GLOSSARY}}": glossary,
            "{{MEMORY}}": safeMemory,
            "{{SCOPE_DESCRIPTION}}": scopeDescription,
            "{{SEARCH_INSTRUCTIONS}}": searchInstructions,
            "{{DOCUMENT_CONTENT}}": content,
        ]
        for (placeholder, value) in replacements { prompt = prompt.replacingOccurrences(of: placeholder, with: value) }

        let identity = currentIdentity(scope: scope, range: included, snapshot: snapshot)
        return ChatContextPlan(
            systemPrompt: prompt,
            mode: mode,
            key: "\(scope.rawValue):\(identity):\(searchMode ? "search" : "inline")",
            label: contextLabel(scope: scope, range: included, snapshot: snapshot),
            estimatedTokens: tokens,
            includedPages: included
        )
    }

    static func estimate(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    static func range(for scope: ChatScope, snapshot: ChatDocumentSnapshot) -> ClosedRange<Int> {
        let last = max(0, snapshot.pageCount - 1)
        switch scope {
        case .visiblePages:
            return max(0, snapshot.visiblePageRange.lowerBound - 1)...min(last, snapshot.visiblePageRange.upperBound + 1)
        case .section:
            return hierarchyRange(level: nil, snapshot: snapshot) ?? 0...last
        case .chapter:
            return hierarchyRange(level: 1, snapshot: snapshot) ?? 0...last
        case .wholeDocument:
            return 0...last
        }
    }

    private static func hierarchyRange(level: Int?, snapshot: ChatDocumentSnapshot) -> ClosedRange<Int>? {
        let sorted = snapshot.toc.sorted { ($0.page, $0.level) < ($1.page, $1.level) }
        let candidates = sorted.enumerated().filter { _, entry in
            entry.page <= snapshot.currentPageIndex && (level == nil || entry.level == level)
        }
        guard let (index, entry) = candidates.max(by: {
            ($0.element.page, $0.element.level) < ($1.element.page, $1.element.level)
        }) else { return nil }
        let end = sorted.dropFirst(index + 1).first(where: { next in
            level == 1 ? next.level == 1 : next.level <= entry.level
        }).map { max(entry.page, $0.page - 1) } ?? max(0, snapshot.pageCount - 1)
        return min(entry.page, end)...min(max(0, snapshot.pageCount - 1), end)
    }

    private static func textForRange(_ range: ClosedRange<Int>, snapshot: ChatDocumentSnapshot) -> String {
        range.compactMap { index in
            guard snapshot.pageTexts.indices.contains(index) else { return nil }
            return "--- p. \(index + 1) ---\n\(snapshot.pageTexts[index])"
        }.joined(separator: "\n\n")
    }

    private static func currentIdentity(scope: ChatScope, range: ClosedRange<Int>, snapshot: ChatDocumentSnapshot) -> String {
        if scope == .wholeDocument { return snapshot.fingerprint }
        return "\(snapshot.fingerprint):\(range.lowerBound)-\(range.upperBound)"
    }

    private static func contextLabel(scope: ChatScope, range: ClosedRange<Int>, snapshot: ChatDocumentSnapshot) -> String {
        let pages = range.lowerBound == range.upperBound
            ? "p. \(range.lowerBound + 1)"
            : "pp. \(range.lowerBound + 1)–\(range.upperBound + 1)"
        let entry = snapshot.toc.filter { $0.page <= snapshot.currentPageIndex }.max {
            ($0.page, $0.level) < ($1.page, $1.level)
        }
        switch scope {
        case .visiblePages: return String(localized: "Context: \(pages) \u{b7} visible text \u{b1}1")
        case .section: return String(localized: "Context: \(entry?.title ?? String(localized: "Section")) \u{b7} \(pages)")
        case .chapter: return String(localized: "Context: \(entry?.title ?? String(localized: "Chapter")) \u{b7} \(pages)")
        case .wholeDocument: return String(localized: "Context: whole PDF \u{b7} \(snapshot.pageCount) pages")
        }
    }

    private static func writeSearchPages(snapshot: ChatDocumentSnapshot, cacheRoot: URL) throws -> URL {
        let safeFingerprint = snapshot.fingerprint.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !safeFingerprint.isEmpty else { throw ChatContextError.cannotWriteSearchIndex }
        let directory = cacheRoot.appendingPathComponent(safeFingerprint, isDirectory: true)
            .appendingPathComponent("pagine", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, text) in snapshot.pageTexts.enumerated() {
                let file = directory.appendingPathComponent(String(format: "p-%04d.txt", index + 1))
                try "Page \(index + 1)\n\n\(text)\n".write(to: file, atomically: true, encoding: .utf8)
            }
            return directory
        } catch {
            throw ChatContextError.cannotWriteSearchIndex
        }
    }
}
