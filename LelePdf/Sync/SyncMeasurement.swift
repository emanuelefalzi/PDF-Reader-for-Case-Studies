import Foundation

/// Sample collection for SPEC §5.8 "How it is measured": active only in
/// Debug builds with the `LELEPDF_MEASURE=1` environment variable, written
/// to `~/Library/Caches/LelePdf/measure/`, never to Desktop/Documents. One
/// instance per window (`DocumentModel.syncCoordinator.measurement`),
/// labeled with the document name so `scripts/measure-sync.sh` can read
/// Merck and Draghi separately.
@MainActor
final class SyncMeasurement {
    struct FrameSample: Codable { var offsetPt: Double; var durationMs: Double }
    struct HoverSample: Codable { var latencyMs: Double }
    struct Report: Codable {
        var label: String
        var frames: [FrameSample]
        var hovers: [HoverSample]
    }

    let label: String
    private(set) var frames: [FrameSample] = []
    private(set) var hovers: [HoverSample] = []

    init(label: String) { self.label = label }

    /// `nil` outside Debug builds or without `LELEPDF_MEASURE=1`: the rest of
    /// the coordinator always checks `measurement != nil`, never the
    /// environment variable directly, so a single place decides.
    static func makeIfEnabled(label: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> SyncMeasurement? {
        #if DEBUG
        guard environment["LELEPDF_MEASURE"] == "1" else { return nil }
        return SyncMeasurement(label: Self.sanitize(label))
        #else
        return nil
        #endif
    }

    private static func sanitize(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    func recordFrame(offsetPt: Double, durationMs: Double) {
        frames.append(FrameSample(offsetPt: offsetPt, durationMs: durationMs))
    }

    func recordHover(latencyMs: Double) {
        hovers.append(HoverSample(latencyMs: latencyMs))
    }

    // TEMPORARY (diagnosing a p95 deviation beyond the threshold): counts
    // how many times the pre-clamp target fell outside the scrollable range,
    // and by how much.
    private(set) var clampCount = 0
    private(set) var totalDriveCount = 0
    private(set) var maxOverflow: Double = 0
    private(set) var pdfRawMin: Double = .infinity
    private(set) var pdfRawMax: Double = -.infinity
    private(set) var pdfMaxScroll: Double = -1
    private(set) var pdfTargetCount = 0
    private(set) var panelRawMin: Double = .infinity
    private(set) var panelRawMax: Double = -.infinity
    private(set) var panelMaxScroll: Double = -1
    private(set) var panelTargetCount = 0
    func recordClampDiagnostic(raw: Double, maxScroll: Double, targetIsPDF: Bool) {
        totalDriveCount += 1
        if targetIsPDF {
            pdfTargetCount += 1
            pdfRawMin = min(pdfRawMin, raw)
            pdfRawMax = max(pdfRawMax, raw)
            pdfMaxScroll = maxScroll
        } else {
            panelTargetCount += 1
            panelRawMin = min(panelRawMin, raw)
            panelRawMax = max(panelRawMax, raw)
            panelMaxScroll = maxScroll
        }
        if raw < 0 {
            clampCount += 1
            maxOverflow = max(maxOverflow, -raw)
        } else if raw > maxScroll {
            clampCount += 1
            maxOverflow = max(maxOverflow, raw - maxScroll)
        }
    }

    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LelePdf/measure", isDirectory: true)
    }

    /// Writes the state collected so far (overwrites the previous file for
    /// the same label): `scripts/measure-sync.sh` reads the latest state
    /// after the automated run, it does not need an append-style format.
    @discardableResult
    func flush() -> URL? {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(label).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Report(label: label, frames: frames, hovers: hovers)) else { return nil }
        try? data.write(to: url, options: .atomic)
        let debugLine = """
        clamp=\(clampCount)/\(totalDriveCount) maxOverflow=\(maxOverflow)
        pdfTarget: n=\(pdfTargetCount) raw=[\(pdfRawMin),\(pdfRawMax)] maxScroll=\(pdfMaxScroll)
        panelTarget: n=\(panelTargetCount) raw=[\(panelRawMin),\(panelRawMax)] maxScroll=\(panelMaxScroll)
        """
        try? debugLine.write(to: dir.appendingPathComponent("\(label)-clamp-debug.txt"), atomically: true, encoding: .utf8)
        return url
    }
}
