import Foundation

/// Path of the fake CLI used by the tests.
///
/// The repository can live on the Desktop (protected by macOS privacy): the
/// ad-hoc signed test app is a "new" app on every build, and any access of its
/// own to the Desktop raises a prompt that nobody approves, blocking the child
/// process. `scripts/test.sh` therefore copies the script to
/// `~/Library/Caches`, from where it runs without restrictions. If the copy is
/// missing, the original path is used.
enum FakeClaudeLocator {
    static let stagedPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/test-staging/fake-claude/claude").path

    static var path: String {
        if FileManager.default.isExecutableFile(atPath: stagedPath) { return stagedPath }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/fake-claude/claude").path
    }
}
