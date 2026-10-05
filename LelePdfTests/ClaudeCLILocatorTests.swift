import Foundation
import Testing
@testable import LelePdf

/// `ClaudeCLILocator` (SPEC §5.11, §13): search order, override, flag check,
/// cache. Each test uses a fresh instance (the `actor` has a synthesized init
/// accessible via `@testable import`) so the cache is not shared from one
/// test to the next. Preferences are injected with a dedicated test domain:
/// never the `UserDefaults.standard` of the app hosting the tests.
@Suite("ClaudeCLILocator")
struct ClaudeCLILocatorTests {
    private static let defaultsKey = ClaudeCLILocator.manualOverrideDefaultsKey

    private static func testDefaults() -> UserDefaults {
        UserDefaults(suiteName: "lelepdf-locator-test-\(UUID())")!
    }

    /// Copies the fake CLI script to a different temporary location, so a
    /// test can tell "the path found is A" from "it is B" even when A and B
    /// behave identically.
    private static func copyFakeCLI(suffix: String) throws -> String {
        let destination = makeTempFilePath("fake-claude-\(suffix)")
        try FileManager.default.copyItem(atPath: FakeClaudeLocator.path, toPath: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)
        return destination
    }

    /// A minimal executable that answers `--version`/`--help` but
    /// deliberately omits `--json-schema` from the flag list, to verify the
    /// capability check (SPEC §13).
    private static func makeCliMissingJsonSchemaFlag() throws -> String {
        let path = makeTempFilePath("fake-claude-missing-flag")
        let script = """
        #!/bin/sh
        case "$1" in
          --version) echo "9.9.9 (fake, flag mancante)";;
          --help) cat <<'EOF'
        Usage: fake
          --safe-mode
          --strict-mcp-config
          --input-format <text>
          --include-partial-messages
          --system-prompt <text>
          --no-session-persistence
        EOF
        ;;
        esac
        exit 0
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test("the environment override wins over the manual one")
    func envOverrideWinsOverManual() async throws {
        let manualCopy = try Self.copyFakeCLI(suffix: "manual")
        defer { try? FileManager.default.removeItem(atPath: manualCopy) }
        let defaults = Self.testDefaults()
        defaults.set(manualCopy, forKey: Self.defaultsKey)

        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let locator = ClaudeCLILocator(defaults: defaults)
            let result = await locator.info()
            let info = try #require(try? result.get())
            #expect(info.path == FakeClaudeLocator.path)
            #expect(info.path != manualCopy)
        }
    }

    @Test("the manual override wins when the environment is not set")
    func manualOverrideUsedWhenEnvAbsent() async throws {
        let manualCopy = try Self.copyFakeCLI(suffix: "manual-only")
        defer { try? FileManager.default.removeItem(atPath: manualCopy) }
        let defaults = Self.testDefaults()
        defaults.set(manualCopy, forKey: Self.defaultsKey)

        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: nil]) {
            let locator = ClaudeCLILocator(defaults: defaults)
            let result = await locator.info()
            let info = try #require(try? result.get())
            #expect(info.path == manualCopy)
        }
    }

    @Test("the fake CLI is usable: all required flags present")
    func capabilityCheckPassesForFakeCli() async throws {
        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path]) {
            let locator = ClaudeCLILocator()
            let result = await locator.info()
            let info = try #require(try? result.get())
            #expect(info.isUsable)
            #expect(info.missingFlags.isEmpty)
            #expect(info.versionString.contains("Claude Code"))
        }
    }

    @Test("a CLI without --json-schema in --help is flagged as not usable")
    func capabilityCheckDetectsMissingFlag() async throws {
        let brokenPath = try Self.makeCliMissingJsonSchemaFlag()
        defer { try? FileManager.default.removeItem(atPath: brokenPath) }

        try await withClaudeTestEnv([ClaudeCLILocator.envOverrideKey: brokenPath]) {
            let locator = ClaudeCLILocator()
            let result = await locator.info()
            let info = try #require(try? result.get())
            #expect(!info.isUsable)
            #expect(info.missingFlags.contains("--json-schema"))
        }
    }

    @Test("the result stays cached: a second info() does not call the CLI again")
    func cachingAvoidsRepeatedSubprocessCalls() async throws {
        let logPath = makeTempFilePath("locator-cache.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }

        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let locator = ClaudeCLILocator()
            _ = await locator.info()
            let afterFirst = readFakeClaudeLog(logPath).count
            #expect(afterFirst > 0)
            _ = await locator.info()
            let afterSecond = readFakeClaudeLog(logPath).count
            #expect(afterSecond == afterFirst)
        }
    }

    @Test("resetCache() forgets the result: the next info() calls the CLI again")
    func resetCacheForcesNewLookup() async throws {
        let logPath = makeTempFilePath("locator-reset.jsonl")
        defer { try? FileManager.default.removeItem(atPath: logPath) }

        try await withClaudeTestEnv([
            ClaudeCLILocator.envOverrideKey: FakeClaudeLocator.path,
            "FAKE_CLAUDE_LOG": logPath,
        ]) {
            let locator = ClaudeCLILocator()
            _ = await locator.info()
            let afterFirst = readFakeClaudeLog(logPath).count
            await locator.resetCache()
            _ = await locator.info()
            let afterSecond = readFakeClaudeLog(logPath).count
            #expect(afterSecond > afterFirst)
        }
    }
}
