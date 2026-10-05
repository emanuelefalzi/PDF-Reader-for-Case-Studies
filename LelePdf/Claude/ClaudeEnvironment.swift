import Foundation

/// Shared environment for `claude` processes (SPEC §7.5, §7.8): an empty
/// working directory outside the repository, and a `PATH` that includes the
/// folder of the CLI that was found (useful when its location is not on a
/// system `PATH`).
enum ClaudeEnvironment {
    /// `~/Library/Caches/LelePdf/cli/`, created if missing, never populated by
    /// us (SPEC §7.5 "Working directory ... empty").
    static func cacheDirectory() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LelePdf/cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Environment inherited from the current process, with the CLI's folder
    /// prepended to `PATH` (SPEC §5.11: the CLI may live in non-standard
    /// locations such as `~/.local/bin`).
    static func baseEnvironment(cliPath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let cliDir = (cliPath as NSString).deletingLastPathComponent
        guard !cliDir.isEmpty else { return env }
        let currentPath = env["PATH"] ?? ""
        if !currentPath.split(separator: ":").map(String.init).contains(cliDir) {
            env["PATH"] = currentPath.isEmpty ? cliDir : "\(cliDir):\(currentPath)"
        }
        return env
    }
}
