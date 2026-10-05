import Foundation
@testable import LelePdf

/// Statistics and report of the F5 benchmark: median, p90 and max per
/// interaction (never the mean alone, which hides stalls), plus the
/// per-stage breakdown read from `PerfProbe` during that interaction alone.
/// Writes a Markdown file to `~/Library/Caches/LelePdf/perf/` (outside the
/// repository) and prints it.
struct PerfBenchStats {
    let samplesMs: [Double]

    var count: Int { samplesMs.count }
    var median: Double { percentile(50) }
    var p90: Double { percentile(90) }
    var max: Double { samplesMs.max() ?? 0 }
    var min: Double { samplesMs.min() ?? 0 }

    func percentile(_ p: Double) -> Double {
        guard !samplesMs.isEmpty else { return 0 }
        let sorted = samplesMs.sorted()
        let rank = Swift.max(0, Swift.min(sorted.count - 1, Int((Double(sorted.count - 1) * p / 100).rounded())))
        return sorted[rank]
    }
}

@MainActor
final class PerfBenchReport {
    struct Row {
        let name: String
        let stats: PerfBenchStats
        let note: String
        let breakdown: [String: PerfProbe.Entry]
    }

    private(set) var rows: [Row] = []
    private(set) var facts: [(String, String)] = []
    /// Free-form sections at the end of the report (F6-ALL: alignment tables).
    private(set) var sections: [(String, String)] = []
    let title: String

    init(title: String) {
        self.title = title
    }

    func fact(_ key: String, _ value: String) {
        facts.append((key, value))
    }

    func section(_ title: String, _ body: String) {
        sections.append((title, body))
    }

    /// Records an interaction: `samplesMs` per repetition, `breakdown` =
    /// `PerfProbe` snapshot accumulated over ALL repetitions (the report
    /// divides it by the number of repetitions).
    func add(_ name: String, samplesMs: [Double], note: String = "", breakdown: [String: PerfProbe.Entry]) {
        rows.append(Row(name: name, stats: PerfBenchStats(samplesMs: samplesMs), note: note, breakdown: breakdown))
    }

    private static func ms(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : (value >= 10 ? String(format: "%.1f", value) : String(format: "%.2f", value))
    }

    func markdown() -> String {
        var out = "# \(title)\n\n"
        for (key, value) in facts { out += "- **\(key)**: \(value)\n" }
        out += "\n## Cost per interaction (ms, wall-clock time on the main thread)\n\n"
        out += "| Interaction | n | median | p90 | max | min | notes |\n|---|---|---|---|---|---|---|\n"
        for row in rows {
            let s = row.stats
            out += "| \(row.name) | \(s.count) | \(Self.ms(s.median)) | \(Self.ms(s.p90)) | \(Self.ms(s.max)) | \(Self.ms(s.min)) | \(row.note) |\n"
        }
        out += "\n## Where the time goes (`PerfProbe` stages, per interaction)\n\n"
        out += "For each stage: how many times it fired PER repetition (n/rep), total milliseconds PER repetition (ms/rep), maximum of a single call (max). The `swiftui.*`/`*.hit` entries are counts only (ms = 0).\n"
        for row in rows {
            let reps = Swift.max(1, row.stats.count)
            let entries = row.breakdown.sorted { ($0.value.totalMs, $0.value.count) > ($1.value.totalMs, $1.value.count) }
            guard !entries.isEmpty else { continue }
            out += "\n### \(row.name)\n\n| stage | n/rep | ms/rep | max ms |\n|---|---|---|---|\n"
            for (label, entry) in entries {
                out += "| `\(label)` | \(String(format: "%.1f", Double(entry.count) / Double(reps))) | \(Self.ms(entry.totalMs / Double(reps))) | \(Self.ms(entry.maxMs)) |\n"
            }
        }
        for (title, body) in sections {
            out += "\n## \(title)\n\n\(body)"
        }
        return out
    }

    /// Saves to `~/Library/Caches/LelePdf/perf/<slug>-<date>.md` and returns
    /// the path.
    @discardableResult
    func save(slug: String) -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LelePdf/perf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("\(slug)-\(formatter.string(from: Date())).md")
        do {
            try markdown().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// Runs `body` `reps` times (after `warmup` discarded repetitions), timing
/// each repetition and accumulating the `PerfProbe` snapshot over the
/// measured repetitions only.
@MainActor
enum PerfBenchRunner {
    struct Outcome {
        var samplesMs: [Double]
        var breakdown: [String: PerfProbe.Entry]
    }

    /// After EVERY repetition a real suspension (`Task.yield()`, outside the
    /// measured time): the body of the `@MainActor` test between two
    /// suspensions is a SINGLE job of the main queue, and everything
    /// PDFKit/CoreAnimation release in autorelease during that job (page
    /// bitmaps at 2×, tens of MB at every scale/scroll) accumulates until the
    /// job ends; `RunLoop.run(until:)` inside `finishFrame` is not enough.
    /// Measured: without this line the `zoom` scenario climbed from 404 to
    /// 1457 MB in 61 frames and returned to 390 MB as soon as the process was
    /// left idle (`LELEPDF_BENCH_HOLD_SECONDS` + `footprint -p`): not an app
    /// leak but an artifact of the harness, which however tripped the memory
    /// guard and prevented the run from finishing. In the real app every
    /// mouse event is a run loop turn of its own, with the pool drained in
    /// between.
    static func run(warmup: Int, reps: Int, _ body: (_ rep: Int) async throws -> Void) async rethrows -> Outcome {
        for i in 0 ..< warmup {
            try await body(-1 - i)
            await Task.yield()
        }
        PerfProbe.reset()
        var samples: [Double] = []
        samples.reserveCapacity(reps)
        for rep in 0 ..< reps {
            let start = CFAbsoluteTimeGetCurrent()
            try await body(rep)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            await Task.yield()
        }
        return Outcome(samplesMs: samples, breakdown: PerfProbe.snapshot(reset: true))
    }
}
