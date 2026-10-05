import AppKit
import Foundation
import Testing

/// The full suite once exceeded 2.7 GB of memory footprint and was killed by
/// the memory watchdog (`scripts/memory-watchdog.sh`) during a diagnostic
/// run: a jump from ~280 MB to 2 GB in ~3 s, correlated (per-line timestamped
/// log) with several suites using real `NSWindow`/`NSHostingView` or real
/// PDFs (Draghi/Merck) "started" in the same second. Each was already
/// `.serialized` internally, but nothing prevented DIFFERENT suites from
/// running at the same moment.
///
/// Each heavy suite becomes a child of THIS enum through
/// `extension HeavyTestSuites { @Suite(...) struct Foo { ... } }` in its own
/// file (no code moved, just a wrapper): the `.serialized` below applies to
/// the direct children, i.e. the nested suites themselves, so two heavy
/// suites never start together, regardless of their own internal
/// `.serialized` (which stays and continues to govern the order of THEIR OWN
/// tests).
@Suite(.serialized)
enum HeavyTestSuites {}

/// Deterministic teardown of a test window created for a render/visual
/// check. Uses EXACTLY the pattern already proven in this codebase
/// (`AnnotationLiveInteractionTests.teardown` and
/// `PerfBench/PerfBenchHost.close()`): **`window.close()` was tried and
/// DISCARDED because it blocks the test process indefinitely** (there is no
/// real window server in an app-hosted test host); `orderOut(nil)` +
/// `contentView = nil` remain the only combination that does not hang. This
/// deliberately deviates from the original plan (which also listed `close()`
/// among the steps): the lesson already recorded in the code is followed
/// instead of the step that contradicts it.
@MainActor
func closeTestWindow(_ window: NSWindow) {
    window.contentView = nil
    window.orderOut(nil)
    RunLoop.current.run(until: Date())
}

/// Memory footprint of the CURRENT PROCESS (`task_vm_info.phys_footprint`,
/// not `mach_task_basic_info.resident_size`/RSS): it is the same quantity
/// shown by `top -stats mem` and used by the watchdog to kill a process. RSS
/// stays small when macOS compresses pages, while the footprint does not.
/// This is an internal per-test guard, distinct from the SPEC §9 budget of
/// the whole app.
enum ProcessFootprint {
    static func bytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }
}

/// Per-test regression guard: a heavy test (render/window/real PDF) calls it
/// around its own body and fails with a clear message if the process
/// footprint grows by more than `maxGrowthBytes` (default 400 MB) during
/// execution. A single test must never, on its own, be the cause of a jump
/// toward the suite's 1.5 GB limit. It does not replace `MemoryBudgetTests`
/// (pipeline budget, SPEC §9): this guard is generic, intended for the
/// rendering/window/export tests of the `HeavyTestSuites` group.
@MainActor
@discardableResult
func expectFootprintGrowthUnderGuard<T>(
    _ label: String,
    maxGrowthBytes: UInt64 = 400_000_000,
    _ body: () throws -> T
) rethrows -> T {
    let before = ProcessFootprint.bytes()
    let result = try body()
    let after = ProcessFootprint.bytes()
    let growth = after > before ? after - before : 0
    #expect(
        growth < maxGrowthBytes,
        "\(label): footprint grew by \(growth / 1_000_000) MB (guard \(maxGrowthBytes / 1_000_000) MB), from \(before / 1_000_000) MB to \(after / 1_000_000) MB"
    )
    return result
}

/// `async` variant (same contract) for tests that measure around `await`
/// code (e.g. background pipeline/analysis).
@MainActor
@discardableResult
func expectFootprintGrowthUnderGuard<T>(
    _ label: String,
    maxGrowthBytes: UInt64 = 400_000_000,
    _ body: () async throws -> T
) async rethrows -> T {
    let before = ProcessFootprint.bytes()
    let result = try await body()
    let after = ProcessFootprint.bytes()
    let growth = after > before ? after - before : 0
    #expect(
        growth < maxGrowthBytes,
        "\(label): footprint grew by \(growth / 1_000_000) MB (guard \(maxGrowthBytes / 1_000_000) MB), from \(before / 1_000_000) MB to \(after / 1_000_000) MB"
    )
    return result
}
