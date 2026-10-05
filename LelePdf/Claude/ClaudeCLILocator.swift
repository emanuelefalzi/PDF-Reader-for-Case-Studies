import Foundation

/// `UserDefaults` is not marked `Sendable` in this build's SDK, even though
/// Apple documents it as thread-safe: without this conformance (not verified
/// by the compiler, but true in practice), passing it as an init parameter to
/// an `actor` (as `ClaudeCLILocatorTests` does to inject a `UserDefaults`
/// domain isolated from `UserDefaults.standard`) failed to compile ("sending
/// 'defaults' risks causing data races"), regardless of explicitly using the
/// `sending` keyword: any non-`Sendable` type crossing the isolation boundary
/// of an actor init needs it anyway.
/// `@retroactive` was added to silence the compiler warning about this
/// retroactive conformance of an imported type/protocol (Swift 6; always
/// present for this kind of declaration until Apple provides the conformance
/// itself). Behavior is unchanged, and `AppRuntime.swift` reuses this same
/// conformance instead of duplicating it with `nonisolated(unsafe)`.
extension UserDefaults: @retroactive @unchecked Sendable {}

/// Finds and inspects the `claude` CLI (SPEC §5.11, §13): search order,
/// manual override, check of the required flags. An `actor` so the result can
/// be cached (SPEC "Cache results") without re-running `--version`/`--help`
/// on every call.
actor ClaudeCLILocator {
    static let shared = ClaudeCLILocator()

    private let defaults: UserDefaults

    init() {
        defaults = AppRuntime.defaults
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// UserDefaults key for the path chosen by hand in Settings (SPEC §5.11).
    static let manualOverrideDefaultsKey = "claudeCLIPath"

    /// Environment variable with the highest precedence: used by tests to
    /// point at the fake CLI (`FakeClaudeLocator.path`).
    static let envOverrideKey = "LELEPDF_CLAUDE_PATH"

    /// Flags verified on 2026-09-14 (SPEC §4) and required by the analysis and
    /// chat calls (SPEC §13 "CLI flag changes in future versions").
    static let requiredFlags = [
        "--json-schema", "--safe-mode", "--strict-mcp-config", "--input-format",
        "--include-partial-messages", "--system-prompt", "--no-session-persistence",
    ]

    private static let fixedCandidates = [
        NSHomeDirectory() + "/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    struct Info: Sendable, Equatable {
        let path: String
        let versionString: String
        let missingFlags: [String]

        var isUsable: Bool { missingFlags.isEmpty }
    }

    enum LocateError: Error, Sendable, Equatable {
        case notFound
    }

    private var cached: Info?

    /// Tests only: forgets the cached result (a different fake-CLI path for
    /// each test, or a changed manual override).
    func resetCache() {
        cached = nil
    }

    /// Path and capabilities of the CLI, cached. Never throws: absence →
    /// `.failure(.notFound)`.
    func info() async -> Result<Info, LocateError> {
        if let cached { return .success(cached) }
        guard let path = resolvePath() else { return .failure(.notFound) }
        let version = await Self.readVersion(path: path)
        let help = await Self.readHelp(path: path)
        let missing = Self.requiredFlags.filter { !help.contains($0) }
        let info = Info(path: path, versionString: version, missingFlags: missing)
        cached = info
        return .success(info)
    }

    /// Only the path, without checking version/flags (used by `ClaudeAuth` and
    /// by `BatchRunner`/`ChatSession` once `info()` has been called at least
    /// once and cached its result).
    private func resolvePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let overridden = env[Self.envOverrideKey] {
            return FileManager.default.isExecutableFile(atPath: overridden) ? overridden : nil
        }
        if let manual = defaults.string(forKey: Self.manualOverrideDefaultsKey),
           !manual.isEmpty, FileManager.default.isExecutableFile(atPath: manual) {
            return manual
        }
        for candidate in Self.fixedCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return Self.commandV()
    }

    /// `zsh -lc 'command -v claude'` with a short time limit (SPEC §5.11): a
    /// login shell reads `.zshrc`/`.zprofile`, where the user may have added
    /// the CLI to `PATH` without it being in one of the fixed locations.
    private static func commandV() -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        // `nonisolated(unsafe)`: the mutation inside the closure and the read
        // after `semaphore.wait()` are synchronized by the semaphore itself
        // (never concurrent in practice), but Swift 6's concurrency checking
        // cannot verify that on its own (the compiler knows no
        // "happens-before" relationship for a `DispatchSemaphore`).
        nonisolated(unsafe) var result: String?
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v claude"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do {
                try process.run()
            } catch {
                semaphore.signal()
                return
            }
            let reader = ClaudePipeReader(pipe.fileHandleForReading)
            if exited.wait(timeout: .now() + 3) == .timedOut {
                process.terminate()
                _ = exited.wait(timeout: .now() + 1)
            }
            let text = reader.text(timeout: 1).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, FileManager.default.isExecutableFile(atPath: text) {
                result = text
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private static func readVersion(path: String) async -> String {
        let result = await OneShotProcess.run(
            executable: path, arguments: ["--version"], environment: ClaudeEnvironment.baseEnvironment(cliPath: path),
            timeout: 10
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readHelp(path: String) async -> String {
        let result = await OneShotProcess.run(
            executable: path, arguments: ["--help"], environment: ClaudeEnvironment.baseEnvironment(cliPath: path),
            timeout: 10
        )
        return result.stdout + "\n" + result.stderr
    }
}
