import Foundation
import AppKit
import Testing
@testable import LelePdf

/// Memory regression for the `align` scenario of the F5 benchmark harness.
/// A Release run of this scenario once grew to a 32 GB footprint and froze
/// the machine; here the same scenario runs in short form (a few steps per
/// phase, a few jumps) on the real views, with the `PerfBenchMemoryGuard`
/// guard active on every frame and the sentinel on a secondary thread, and
/// the footprint growth must stay under the guard's limit. Skipped if the
/// staged PDF is missing (like the other suites on the test PDFs).
extension HeavyTestSuites {
@MainActor
@Suite("Alignment scenario memory", .serialized)
struct AlignmentMemoryTests {
    @Test("the short align scenario keeps memory bounded")
    func alignScenarioMemoryIsBounded() async throws {
        guard TestPDFs.ensureAvailable(TestPDFs.merck) else {
            print("SKIP: test PDF not found at \(TestPDFs.merck.path)")
            return
        }
        PerfBenchMemoryGuard.startSentinel()
        defer { PerfBenchMemoryGuard.stopSentinel() }
        PerfProbe.isEnabled = true
        defer { PerfProbe.isEnabled = false }

        let size = CGSize(width: 1440, height: 900)
        let built = try await PerfBenchDocument.build(pdfURL: TestPDFs.merck, analyzedFraction: 0.4, marksPerBlock: 12)
        let host = PerfBenchHost(model: built.model, size: size, onScreen: false)
        try await host.settle()
        defer { host.close() }
        host.memoryGuard.start()

        let config = HeavyTestSuites.PerformanceBenchmarkTests.Config(
            pdfURL: TestPDFs.merck, windowSize: size, reps: 1, analyzedFraction: 0.4, marksPerBlock: 12, onScreen: false, only: ["align"]
        )
        let report = PerfBenchReport(title: "Memory regression (align, short)")
        let bench = PerfBenchScenarios(host: host, built: built, config: config, report: report)
        let steps = Int(ProcessInfo.processInfo.environment["LELEPDF_BENCH_ALIGN_STEPS"] ?? "") ?? 40
        try await bench.alignment(maxSteps: steps)

        let guardian = host.memoryGuard
        print("AlignmentMemoryTests: \(guardian.summary)")
        #expect(guardian.checks > 0)
        #expect(guardian.peakMB - guardian.startMB < PerfBenchMemoryGuard.growthLimitMB, "footprint growth \(guardian.summary)")
        #expect(guardian.peakMB < PerfBenchMemoryGuard.absoluteLimitMB, "absolute footprint \(guardian.summary)")
        let sync = built.model.syncCoordinator
        print("AlignmentMemoryTests: automatic drives \(sync.automaticRedriveCount), budget exhausted \(sync.automaticRedriveBudgetExhaustedCount) times")
        #expect(sync.automaticRedriveBudgetExhaustedCount == 0, "the automatic-drive budget must not run out in normal use")
    }
}
}
