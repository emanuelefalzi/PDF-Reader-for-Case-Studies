import Foundation
import os

/// Performance measurement probe: counts and times the "hot" paths of
/// the UI (overlay redraws, alignment rebuilds, card layout, re-evaluated
/// SwiftUI bodies...) so the benchmark
/// (`LelePdfTests/PerformanceBenchmarkTests.swift`) can tell at which stage
/// the time of each interaction goes, in milliseconds rather than by feel.
///
/// **Idle cost**: when `isEnabled` is false (the production default) every
/// call is a single `Bool` check and returns immediately: no dictionary is
/// touched, no `signpost` is emitted. It is turned on with the
/// `LELEPDF_PERF_PROBE=1` environment variable (useful with Instruments:
/// the same intervals are also emitted as `os_signpost` in the
/// `com.emanuele.LelePdf` subsystem, category `perf`) or by the benchmark
/// (`PerfProbe.isEnabled = true`).
///
/// MainActor: all instrumented points already live on the main thread
/// (PDFKit, AppKit, SwiftUI), and counting must never cost a lock.
@MainActor
enum PerfProbe {
    struct Entry: Sendable, Equatable {
        var count: Int = 0
        var totalMs: Double = 0
        var maxMs: Double = 0
    }

    static var isEnabled: Bool = ProcessInfo.processInfo.environment["LELEPDF_PERF_PROBE"] == "1"

    private static var entries: [String: Entry] = [:]
    private static let signposter = OSSignposter(subsystem: "com.emanuele.LelePdf", category: "perf")

    /// Times `body` under `label`, accumulating count, total and maximum.
    /// Re-entrant: an interval nested inside another is counted both times
    /// (each label is independent).
    @discardableResult
    static func measure<T>(_ label: StaticString, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let state = signposter.beginInterval(label)
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            signposter.endInterval(label, state)
            record(label: "\(label)", elapsedMs: elapsedMs)
        }
        return try body()
    }

    /// Count only (for example "how many times a SwiftUI view's `body` was
    /// re-evaluated"), no timing.
    static func hit(_ label: StaticString) {
        guard isEnabled else { return }
        signposter.emitEvent(label)
        record(label: "\(label)", elapsedMs: 0)
    }

    /// Records an interval timed elsewhere (for example around an `await`,
    /// which the synchronous `measure` cannot wrap).
    static func record(_ label: StaticString, elapsedMs: Double) {
        guard isEnabled else { return }
        record(label: "\(label)", elapsedMs: elapsedMs)
    }

    private static func record(label: String, elapsedMs: Double) {
        var entry = entries[label] ?? Entry()
        entry.count += 1
        entry.totalMs += elapsedMs
        entry.maxMs = max(entry.maxMs, elapsedMs)
        entries[label] = entry
    }

    /// Snapshot of all counters (label -> entry), optionally reset
    /// afterwards.
    static func snapshot(reset: Bool = false) -> [String: Entry] {
        let copy = entries
        if reset { entries.removeAll() }
        return copy
    }

    static func reset() {
        entries.removeAll()
    }
}
