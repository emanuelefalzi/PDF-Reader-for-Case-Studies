import Foundation
@testable import LelePdf

/// Memory guard for the benchmark harness (F6-ALL, 2026-09-21: two runs of
/// the `align` scenario climbed to 31 and 38 GB of footprint on an 8 GB Mac,
/// filled swap and disk and locked up the machine; the cause was a
/// synchronous re-drive loop in the scroll alignment code). Two levels, both
/// on the **physical footprint** (`ProcessMemory.footprintBytes`,
/// `task_vm_info.phys_footprint`): RSS is useless, at 38 GB of footprint it
/// read 16 MB because the pages were compressed or on disk.
///
/// 1. `check(step:)` after every frame (`PerfBenchScenarios.finishFrame`):
///    fails the scenario immediately, with the numbers, if it exceeds
///    `absoluteLimitMB` or grows more than `growthLimitMB` since the start.
/// 2. `startSentinel()`: a secondary thread that re-reads the footprint every
///    200 ms and terminates the process (message on stderr, `_exit`) if it
///    exceeds `sentinelLimitMB`. It covers the case in which the main thread
///    never comes back (a loop inside `layoutSubtreeIfNeeded`, as it was),
///    where no "after the step" check can intervene.
///
/// `scripts/memory-watchdog.sh` (2.5 GB, external) remains the last line.
@MainActor
final class PerfBenchMemoryGuard {
    nonisolated static let absoluteLimitMB: Double = 1500
    /// The growth cap used to be fixed at 300 MB, tuned on the `align`
    /// scenario (small window, +44 MB); with the harness window at 1920×1080
    /// pt at 2× scale, scrolling the Merck case through its pages grows
    /// PDFKit's render cache by ~330 MB in 30 frames (measured with
    /// `LELEPDF_BENCH_MEMLOG=1`), and the `lele` benchmark never reached the
    /// end. `LELEPDF_BENCH_GROWTH_MB` raises the cap ONLY for that run; the
    /// default stays 300, the absolute limit (1500) and the sentinel (2000)
    /// do not change.
    nonisolated static let growthLimitMB: Double = Double(ProcessInfo.processInfo.environment["LELEPDF_BENCH_GROWTH_MB"] ?? "") ?? 300
    nonisolated static let sentinelLimitMB: Double = 2000

    struct Runaway: Error, CustomStringConvertible {
        let step: String
        let footprintMB: Double
        let startMB: Double
        let peakMB: Double
        let checks: Int

        var description: String {
            String(format: "runaway memory at step \"%@\": footprint %.0f MB (start %.0f MB, +%.0f MB; absolute limit %.0f MB, growth limit +%.0f MB; peak %.0f MB; %d checks)",
                   step, footprintMB, startMB, footprintMB - startMB, PerfBenchMemoryGuard.absoluteLimitMB, PerfBenchMemoryGuard.growthLimitMB, peakMB, checks)
        }
    }

    private(set) var startMB: Double = 0
    private(set) var peakMB: Double = 0
    private(set) var checks = 0
    private var started = false

    nonisolated static func footprintMB() -> Double {
        Double(ProcessMemory.footprintBytes()) / 1_048_576
    }

    /// Fixes the starting point (after `PerfBenchHost.settle`: window
    /// mounted, document analyzed, thumbnails done).
    func start() {
        startMB = Self.footprintMB()
        peakMB = startMB
        checks = 0
        started = true
    }

    /// The growth cap trips only if exceeded on TWO consecutive checks. A
    /// single frame can transiently inflate the footprint by hundreds of MB
    /// (measured: +440 MB in a single frame when the PDF re-fits to a new
    /// sidebar width, all released on the next run loop turn: autoreleased
    /// PDFKit/CoreAnimation objects, not retained memory); the F6-ALL loop,
    /// by contrast, grew for dozens of frames in a row and is still caught at
    /// the second check. The absolute limit and the sentinel have no
    /// tolerance.
    private var growthStrikes = 0

    /// To be called after every measured step. Cost: one `task_info`.
    func check(step: String = "") throws {
        if !started { start() }
        checks += 1
        let now = Self.footprintMB()
        peakMB = max(peakMB, now)
        if now > Self.absoluteLimitMB {
            throw Runaway(step: step, footprintMB: now, startMB: startMB, peakMB: peakMB, checks: checks)
        }
        if now - startMB > Self.growthLimitMB {
            growthStrikes += 1
            if growthStrikes >= 2 {
                throw Runaway(step: step, footprintMB: now, startMB: startMB, peakMB: peakMB, checks: checks)
            }
        } else {
            growthStrikes = 0
        }
    }

    var summary: String {
        String(format: "footprint at start %.0f MB, peak %.0f MB (+%.0f MB), %d checks", startMB, peakMB, peakMB - startMB, checks)
    }

    // MARK: - Sentinel on a secondary thread

    nonisolated private static let sentinelLock = NSLock()
    nonisolated(unsafe) private static var sentinelStarted = false
    /// True only between `startSentinel()` and `stopSentinel()`: the sentinel
    /// judges ONLY during the scenario that armed it. In the first run of the
    /// full suite (2026-09-21, evening) it was armed by
    /// `AlignmentMemoryTests` (alphabetically among the first suites), stayed
    /// on guard over the whole Debug process and terminated the process at
    /// 2070 MB during the visual-check suite (PNG screenshots), after 644
    /// tests had passed: the normal cumulative footprint of 145 suites with
    /// dozens of PDFs loaded, not a loop. The process was relaunched by
    /// xcodebuild; per the safety rule the session stopped there. This
    /// arming logic was added after that run.
    nonisolated(unsafe) private static var sentinelArmed = false

    nonisolated private static var isSentinelArmed: Bool {
        sentinelLock.lock()
        defer { sentinelLock.unlock() }
        return sentinelArmed
    }

    /// Disarms the sentinel (the thread stays alive but no longer judges).
    nonisolated static func stopSentinel() {
        sentinelLock.lock()
        defer { sentinelLock.unlock() }
        sentinelArmed = false
    }

    /// Arms the sentinel and starts the thread (once per process).
    nonisolated static func startSentinel() {
        sentinelLock.lock()
        defer { sentinelLock.unlock() }
        sentinelArmed = true
        guard !sentinelStarted else { return }
        sentinelStarted = true
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.2)
                guard isSentinelArmed else { continue }
                let now = footprintMB()
                if now > sentinelLimitMB {
                    let message = String(format: "\nMEMORY SENTINEL (PerfBenchMemoryGuard): footprint %.0f MB > %.0f MB, the main thread is not coming back: terminating the process.\n", now, sentinelLimitMB)
                    FileHandle.standardError.write(Data(message.utf8))
                    _exit(70)
                }
            }
        }
        thread.name = "LelePdf.PerfBenchMemoryGuard.sentinel"
        thread.qualityOfService = .utility
        thread.start()
    }
}
