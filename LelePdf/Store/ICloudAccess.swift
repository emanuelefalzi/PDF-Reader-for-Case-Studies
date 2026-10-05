import Foundation

/// Access to data files with iCloud support (SPEC §8): before reading, it
/// checks `ubiquitousItemDownloadingStatus`, downloads if needed, and
/// reads/writes go through `NSFileCoordinator`. Pure/static functions doing
/// synchronous I/O: used only inside the `DocumentStore` actor, never on the
/// MainActor (SPEC §6.3), so they do not block the interface.
enum ICloudAccess {
    /// True if the file does not exist yet (nothing to download) or is already
    /// available locally. If it is a not-yet-downloaded iCloud file, it
    /// requests the download and waits with a short, bounded wait (not an
    /// indefinite block): the wait happens on the actor's executor, not on the
    /// MainActor.
    static func ensureDownloaded(_ url: URL, maxWait: TimeInterval = 8) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let status = downloadingStatus(of: url), status != .current else { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            if downloadingStatus(of: url) == .current { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return downloadingStatus(of: url) == .current
    }

    private static func downloadingStatus(of url: URL) -> URLUbiquitousItemDownloadingStatus? {
        try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
    }

    /// Coordinated read (SPEC §8 "Reads and writes go through
    /// NSFileCoordinator"). `nil` if the file is missing, cannot be
    /// downloaded in time, or the read fails.
    static func coordinatedRead(_ url: URL) -> Data? {
        guard ensureDownloaded(url) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var result: Data?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
            result = try? Data(contentsOf: coordinatedURL)
        }
        return result
    }

    /// Coordinated + atomic write (temporary file and replace,
    /// `AtomicJSONFile.write`).
    static func coordinatedWrite(_ data: Data, to url: URL, keepBackup: Bool) throws {
        var thrown: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            do {
                try AtomicJSONFile.write(data, to: coordinatedURL, keepBackup: keepBackup)
            } catch {
                thrown = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let thrown { throw thrown }
    }

    /// Synchronous read-modify-write transaction on the same file. Unlike a
    /// coordinated read followed later by a coordinated write, it holds the
    /// coordination for the entire merge and keeps two processes from both
    /// reading an old version and then overwriting each other.
    static func coordinatedUpdate<T>(_ url: URL, body: (URL) throws -> T) throws -> T {
        guard ensureDownloaded(url) else {
            throw CocoaError(.fileReadUnknown)
        }
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            result = Result { try body(coordinatedURL) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }
}
