import Foundation

/// Paths of the test PDFs (SPEC §4, read-only, never copied into the
/// repository). Tests that use them skip with a clear message if they are
/// missing or not yet downloaded from iCloud.
enum TestPDFs {
    /// Local copies prepared by `scripts/test.sh` outside the Desktop (see
    /// the script): the ad-hoc signed test app must never even attempt the
    /// fallback to the protected original files. If a copy is missing, the
    /// real tests skip it via `ensureAvailable`.
    static let stagingDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/LelePdf/test-staging/pdfs", isDirectory: true)

    static let draghi = stagingDir.appendingPathComponent("draghi.pdf")
    static let merck = stagingDir.appendingPathComponent("merck.pdf")
    /// The HBS case "Sony's Response to the Wii" (`TIS-Nintendo Wii.pdf`, the
    /// author's course material, same read-only treatment as the other two:
    /// never copied into the repository).
    static let wii = stagingDir.appendingPathComponent("wii.pdf")
    /// The HBS case "Ockham Technologies (A): Building the Team"
    /// (`L7 - Ockham.pdf`, the author's course material), where the author
    /// first saw "Buuildingg the Teeam": the real PDF on which the cause of
    /// the defect was confirmed (doubled letters from simulated bold/OCR),
    /// same read-only treatment as the other test PDFs.
    static let ockham = stagingDir.appendingPathComponent("ockham.pdf")

    /// Per-file result cache: several tests use the same PDF, and the
    /// availability check must not be repeated for each of them. `NSLock`
    /// instead of an actor because this function is called from synchronous
    /// code not isolated to the MainActor.
    private static let availabilityLock = NSLock()
    private static nonisolated(unsafe) var availabilityCache: [String: Bool] = [:]

    /// True if the file is present and its bytes are downloaded from iCloud,
    /// `false` if the test calling it must skip.
    ///
    /// Checks the state with `URLResourceValues.ubiquitousItemDownloadingStatus`
    /// instead of always invoking `brctl` (or worse, sleeping): the test PDFs
    /// are already downloaded at session start (SPEC §10.4), so in the normal
    /// case this is only a metadata read, without starting any process. Only
    /// if the state is not `.current` is the download requested and awaited
    /// with a short, bounded wait (max ~4 s).
    static func ensureAvailable(_ url: URL) -> Bool {
        availabilityLock.lock()
        if let cached = availabilityCache[url.path] {
            availabilityLock.unlock()
            return cached
        }
        availabilityLock.unlock()

        let result = resolveAvailability(url)

        availabilityLock.lock()
        availabilityCache[url.path] = result
        availabilityLock.unlock()
        return result
    }

    private static func resolveAvailability(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        if let status = downloadingStatus(of: url), status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            for _ in 0..<20 {
                if downloadingStatus(of: url) == .current { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func downloadingStatus(of url: URL) -> URLUbiquitousItemDownloadingStatus? {
        var url = url
        return try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
    }
}
