import Foundation
@testable import LelePdf

/// Serializes the Claude-module tests that read/write shared process
/// environment variables (`LELEPDF_CLAUDE_PATH`, `FAKE_CLAUDE_MODE`,
/// `FAKE_CLAUDE_MODE_FILE`, ...): Swift Testing normally runs suites in
/// parallel, and `ProcessInfo.processInfo.environment` plus
/// `ClaudeCLILocator.shared` are process state shared by all tests. Without
/// this, two parallel tests setting different fake CLI modes could interfere
/// with each other.
actor ClaudeTestLock {
    static let shared = ClaudeTestLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        locked = true
    }

    func release() {
        guard !waiters.isEmpty else {
            locked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

/// Runs `body` with the given variables set in the test process environment
/// (which the fake CLI inherits through `ClaudeEnvironment.baseEnvironment`),
/// restoring the previous values at the end. Serialized with
/// `ClaudeTestLock`. Also resets the `ClaudeCLILocator.shared` cache before
/// and after, so every test starts clean regardless of which CLI (fake or
/// real) was resolved earlier.
func withClaudeTestEnv<T: Sendable>(
    _ vars: [String: String?],
    _ body: () async throws -> T
) async rethrows -> T {
    await ClaudeTestLock.shared.acquire()
    defer {
        Task { await ClaudeTestLock.shared.release() }
    }
    var previous: [(String, String?)] = []
    for (key, value) in vars {
        previous.append((key, ProcessInfo.processInfo.environment[key]))
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
    await ClaudeCLILocator.shared.resetCache()
    defer {
        for (key, value) in previous {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }
    let result = try await body()
    await ClaudeCLILocator.shared.resetCache()
    return result
}

/// Variant for AppKit/`@Observable` suites confined to the MainActor. Avoids
/// sending a closure that captures UI state to a generic context while the
/// environment variables are temporarily changed.
@MainActor
func withClaudeMainActorTestEnv<T: Sendable>(
    _ vars: [String: String?],
    _ body: @MainActor () async throws -> T
) async rethrows -> T {
    await ClaudeTestLock.shared.acquire()
    defer { Task { await ClaudeTestLock.shared.release() } }
    var previous: [(String, String?)] = []
    for (key, value) in vars {
        previous.append((key, ProcessInfo.processInfo.environment[key]))
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
    }
    await ClaudeCLILocator.shared.resetCache()
    defer {
        for (key, value) in previous {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
    let result = try await body()
    await ClaudeCLILocator.shared.resetCache()
    return result
}

/// Path of a temporary file exclusive to a test (log, mode-file,
/// fixtures...): under `NSTemporaryDirectory()`, never inside the repository,
/// and deleted at the end of the test by the caller.
func makeTempFilePath(_ name: String) -> String {
    NSTemporaryDirectory() + "lelepdf-test-\(UUID().uuidString)-\(name)"
}

/// Reads the JSONL lines written by `FAKE_CLAUDE_LOG` as an array of dictionaries.
func readFakeClaudeLog(_ path: String) -> [[String: Any]] {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return contents.split(separator: "\n").compactMap { line in
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// How many "real" invocations (`-p ...`, one-shot or chat) appear in the
/// log, excluding the `--version`/`--help` probes that
/// `ClaudeCLILocator.info()` runs every time its cache is reset
/// (`withClaudeTestEnv` does so before each test): without this filter,
/// counting all the log lines would also include those two probes, which are
/// not calls made by the test.
func fakeClaudeBusyInvocationCount(_ path: String) -> Int {
    readFakeClaudeLog(path).filter { ($0["argv"] as? [String])?.first == "-p" }.count
}
