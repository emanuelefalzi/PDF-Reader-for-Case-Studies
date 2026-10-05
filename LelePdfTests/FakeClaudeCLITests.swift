import Foundation
import Testing

/// Verifies that the fake CLI (scripts/fake-claude/claude, SPEC §10.2) is
/// executable and responds plausibly to the commands the app uses.
@Suite("Fake claude CLI")
struct FakeClaudeCLITests {
    /// Walks up from the location of this source file to the repo root.
    static var repoRoot: URL {
        // .../LelePdfTests/FakeClaudeCLITests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var cliPath: String { FakeClaudeLocator.path }

    struct CLITimeout: Error, CustomStringConvertible {
        let arguments: [String]
        let seconds: TimeInterval
        var description: String { "the fake CLI did not finish within \(seconds) s: \(arguments)" }
    }

    /// Reads a pipe until EOF on a background queue, so stdout and stderr
    /// drain in parallel and the child never stalls on a full pipe.
    final class PipeReader: @unchecked Sendable {
        private let group = DispatchGroup()
        private var data = Data()

        init(_ handle: FileHandle) {
            group.enter()
            DispatchQueue.global().async {
                self.data = handle.readDataToEndOfFile()
                self.group.leave()
            }
        }

        func text(timeout: TimeInterval) -> String {
            guard group.wait(timeout: .now() + timeout) == .success else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    @discardableResult
    static func run(_ arguments: [String], input: String? = nil, env: [String: String] = [:], timeout: TimeInterval = 15) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // With no input, stdin is /dev/null: the child does not inherit the test host's.
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let outReader = PipeReader(outPipe.fileHandleForReading)
        let errReader = PipeReader(errPipe.fileHandleForReading)

        if let input, let inPipe {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try inPipe.fileHandleForWriting.close()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
            throw CLITimeout(arguments: arguments, seconds: timeout)
        }

        return (
            process.terminationStatus,
            outReader.text(timeout: 2),
            errReader.text(timeout: 2)
        )
    }

    @Test("the script exists and is executable")
    func cliExists() throws {
        #expect(FileManager.default.isExecutableFile(atPath: Self.cliPath))
    }

    @Test("--version prints the expected version string")
    func version() throws {
        let result = try Self.run(["--version"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("Claude Code"))
    }

    @Test("auth status returns valid JSON with loggedIn true")
    func authStatusLoggedIn() throws {
        let result = try Self.run(["auth", "status"])
        #expect(result.status == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(json["loggedIn"] as? Bool == true)
    }

    @Test("auth status in not_logged_in mode returns loggedIn false and exit 1")
    func authStatusNotLoggedIn() throws {
        let result = try Self.run(["auth", "status"], env: ["FAKE_CLAUDE_MODE": "not_logged_in"])
        #expect(result.status == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(json["loggedIn"] as? Bool == false)
    }

    @Test("-p with --output-format json returns a result object with a valid structured_output")
    func oneShotSuccess() throws {
        let result = try Self.run([
            "-p", "Il testo parla di Merck e della FDA che approva il farmaco.",
            "--model", "sonnet", "--safe-mode", "--tools", "", "--strict-mcp-config",
            "--no-session-persistence", "--system-prompt", "sys", "--json-schema", "{}",
            "--output-format", "json",
        ])
        #expect(result.status == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(json["type"] as? String == "result")
        #expect(json["is_error"] as? Bool == false)
        let structured = try #require(json["structured_output"] as? [String: Any])
        let marks = try #require(structured["marks"] as? [[String: Any]])
        #expect(marks.count == 8)
        let kinds = Set(marks.compactMap { $0["mark"] as? String })
        #expect(kinds == ["rectangle", "circle", "underline", "arrow"])
    }

    @Test("--json-schema with \"entries\" returns an output shaped like a table of contents")
    func oneShotToc() throws {
        let result = try Self.run(["-p", "candidati", "--json-schema", "{\"entries\":[]}", "--output-format", "json"])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let structured = try #require(json["structured_output"] as? [String: Any])
        #expect(structured["entries"] != nil)
    }

    @Test("rate_limit mode returns is_error true with the limit message")
    func rateLimit() throws {
        let result = try Self.run(["-p", "x", "--output-format", "json"], env: ["FAKE_CLAUDE_MODE": "rate_limit"])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(json["is_error"] as? Bool == true)
        let text = try #require(json["result"] as? String)
        #expect(text.contains("usage limit reached"))
    }

    @Test("chat mode: system/stream_event/assistant/result events in order")
    func chatStream() throws {
        let inputLine = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Domanda di prova\"}]}}\n"
        let result = try Self.run([
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--model", "sonnet",
        ], input: inputLine)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(!lines.isEmpty)
        let types: [String] = try lines.map { line in
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try #require(obj["type"] as? String)
        }
        #expect(types.first == "system")
        #expect(types.contains("stream_event"))
        #expect(types.contains("assistant"))
        #expect(types.last == "result")
    }

    @Test("FAKE_CLAUDE_LOG records the invocation's arguments")
    func logsInvocation() throws {
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: logURL) }
        _ = try Self.run(["--version"], env: ["FAKE_CLAUDE_LOG": logURL.path])
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        #expect(contents.contains("--version"))
    }
}
