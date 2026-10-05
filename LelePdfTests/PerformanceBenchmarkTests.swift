import Foundation
import AppKit
@preconcurrency import PDFKit
import Testing
@testable import LelePdf

/// Performance benchmark: drives the REAL views (window, `PDFView` with the
/// three overlays, right panel in `RewriteScrollHost`, sidebar) on a SPEC §4
/// test PDF with a realistic analyzed document (`PerfBenchDocument`), and
/// measures the wall-clock cost of each interaction (median, p90 and maximum
/// over many repetitions) plus the per-stage breakdown (`PerfProbe`).
///
/// **Skipped by default** (same scheme as `MemoryBudgetTests`): run it with
/// `LELEPDF_MEASURE_PERF=1 scripts/test.sh`. The suite is nested in
/// `HeavyTestSuites`, so select it with
/// `LELEPDF_TEST_ONLY=HeavyTestSuites/PerformanceBenchmarkTests` (plain
/// `LELEPDF_TEST_ONLY=PerformanceBenchmarkTests` selects nothing). Best
/// together with `LELEPDF_TEST_CONFIGURATION=Release` (numbers comparable to
/// the installed app). Optional variables: `LELEPDF_BENCH_PDF=merck|draghi`,
/// `LELEPDF_BENCH_WINDOW=1920x1080`, `LELEPDF_BENCH_REPS=30`,
/// `LELEPDF_BENCH_FRACTION=1.0` (share of analyzed blocks),
/// `LELEPDF_BENCH_MARKS=12` (marks per block), `LELEPDF_BENCH_ONSCREEN=1`
/// (real on-screen window), `LELEPDF_BENCH_ONLY=scroll,hover,...,align`.
/// The Markdown report ends up in `~/Library/Caches/LelePdf/perf/`.
extension HeavyTestSuites {
@MainActor
@Suite("F5 · performance benchmark", .serialized)
struct PerformanceBenchmarkTests {
    struct Config {
        let pdfURL: URL
        let windowSize: CGSize
        let reps: Int
        let analyzedFraction: Double
        let marksPerBlock: Int
        let onScreen: Bool
        let only: Set<String>?
        /// `LELEPDF_BENCH_SIDEBAR_TAB=pagine|indice|mappa`: the sidebar tab
        /// mounted in the benchmark window (by default the one remembered per
        /// app, i.e. Pages in a clean test domain). With `indice` the
        /// scroll/jump measurements also go through `ChaptersSidebar`
        /// (highlighting of the current entry).
        var sidebarTab: SidebarTab? = nil

        static func fromEnvironment() -> Config {
            let env = ProcessInfo.processInfo.environment
            let pdf = env["LELEPDF_BENCH_PDF"] == "draghi" ? TestPDFs.draghi : TestPDFs.merck
            var size = CGSize(width: 1920, height: 1080)
            if let raw = env["LELEPDF_BENCH_WINDOW"] {
                let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
            }
            let only = env["LELEPDF_BENCH_ONLY"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
            return Config(
                pdfURL: pdf, windowSize: size,
                reps: Int(env["LELEPDF_BENCH_REPS"] ?? "") ?? 30,
                // 0.4 by default: the user's real-world state (the first
                // pages analyzed, the rest not). With 1.0 the worst case of a
                // fully studied document is measured.
                analyzedFraction: Double(env["LELEPDF_BENCH_FRACTION"] ?? "") ?? 0.4,
                marksPerBlock: Int(env["LELEPDF_BENCH_MARKS"] ?? "") ?? 12,
                onScreen: env["LELEPDF_BENCH_ONSCREEN"] == "1",
                only: only,
                sidebarTab: env["LELEPDF_BENCH_SIDEBAR_TAB"].flatMap(SidebarTab.init(rawValue:))
            )
        }

        func wants(_ scenario: String) -> Bool { only?.contains(scenario) ?? true }
    }

    static var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    /// One pass of the main run loop without waiting: delivers PDFKit's
    /// deferred notifications and the SwiftUI commit, as happens between one
    /// event and the next frame in the app.
    static func spinOnce() {
        RunLoop.main.run(mode: .default, before: Date())
    }

    @Test("measures the cost of each interaction on the real views (LELEPDF_MEASURE_PERF=1)")
    func benchmark() async throws {
        guard ProcessInfo.processInfo.environment["LELEPDF_MEASURE_PERF"] == "1" else {
            print("PerformanceBenchmarkTests: skip (LELEPDF_MEASURE_PERF is not \"1\"): slow bench, not part of the regular suite; to run it: LELEPDF_MEASURE_PERF=1 LELEPDF_TEST_ONLY=PerformanceBenchmarkTests scripts/test.sh")
            return
        }
        let config = Config.fromEnvironment()
        guard TestPDFs.ensureAvailable(config.pdfURL) else {
            print("SKIP: PDF fixture not found in \(config.pdfURL.path)")
            return
        }

        PerfProbe.isEnabled = true
        defer { PerfProbe.isEnabled = false }

        let built = try await PerfBenchDocument.build(pdfURL: config.pdfURL, analyzedFraction: config.analyzedFraction, marksPerBlock: config.marksPerBlock)
        if let sidebarTab = config.sidebarTab { built.model.sidebarTab = sidebarTab }
        let host = PerfBenchHost(model: built.model, size: config.windowSize, onScreen: config.onScreen)
        try await host.settle()
        defer { host.close() }
        // Memory guard: starting point after mounting; the sentinel starts
        // first of all (absolute limit).
        PerfBenchMemoryGuard.startSentinel()
        defer { PerfBenchMemoryGuard.stopSentinel() }
        host.memoryGuard.start()
        defer { print("F5 BENCH: memory — \(host.memoryGuard.summary)") }

        let report = PerfBenchReport(title: "F5 · performance benchmark (\(Self.buildConfiguration))")
        report.fact("configuration", "\(Self.buildConfiguration), window \(Int(config.windowSize.width))×\(Int(config.windowSize.height)) pt, scale \(host.window.backingScaleFactor)×, \(config.onScreen ? "on screen" : "off screen")")
        report.fact("document", "\(config.pdfURL.lastPathComponent), \(built.model.pageCount) pages, \(built.structure.blocks.count) blocks (\(built.analyzedBlockCount) analyzed, \(built.markCount) marks), \(built.tocEntries.count) index entries, pipeline \(String(format: "%.2f", built.pipelineSeconds)) s")
        if let pdfView = host.pdfView {
            report.fact("panels", "PDF \(Int(pdfView.bounds.width))×\(Int(pdfView.bounds.height)) pt, visible pages \(built.model.visiblePageRange), right panel \(Int(built.model.rightPanelWidth)) pt, alignment segments \(built.model.syncCoordinator.segments.count)")
        }
        report.fact("sidebar", "tab \(built.model.sidebarTab.rawValue) (\(config.sidebarTab == nil ? "the one remembered per app" : "LELEPDF_BENCH_SIDEBAR_TAB"))")
        report.fact("repetitions", "\(config.reps) per interaction (plus 3 discarded warm-up runs)")
        report.fact("memory at the start of the measurements", "\(String(format: "%.0f", host.memoryGuard.startMB)) MB footprint (guard: \(Int(PerfBenchMemoryGuard.absoluteLimitMB)) MB absolute, +\(Int(PerfBenchMemoryGuard.growthLimitMB)) MB growth)")
        report.fact("first full window layout (document already analyzed)", "\(String(format: "%.0f", host.firstLayoutMs)) ms, second pass \(String(format: "%.0f", host.secondLayoutMs)) ms")
        report.fact("full PDFView rasterization (PDFKit + overlays, one-off)", "\(String(format: "%.1f", host.rasterizePDFViewMs())) ms")

        let bench = PerfBenchScenarios(host: host, built: built, config: config, report: report)
        // Step label for the memory guard and for `LELEPDF_BENCH_MEMLOG=1`
        // (previously only the `align` scenario set it: a guard error in the
        // other scenarios came out with an empty step and it was unclear
        // where it had tripped).
        func step(_ label: String, _ body: () async throws -> Void) async throws {
            host.memoryGuardStep = label
            try await body()
        }
        // `LELEPDF_BENCH_HOLD_SECONDS=N` keeps the process alive for N
        // seconds at the end (even after a guard error), so an external
        // sampler (`footprint -p <pid>`) can read the memory categories at
        // the peak: the only way to tell PDFKit's rendering cache
        // (CoreAnimation/IOSurface) apart from our own malloc.
        let holdSeconds = Double(ProcessInfo.processInfo.environment["LELEPDF_BENCH_HOLD_SECONDS"] ?? "") ?? 0
        do {
        try await step("baseline") { try await bench.baseline() }
        // First the four symptoms reported by the user. They can also run one
        // by one (`p1`..`p4`), so each symptom can run in its own process
        // when PDFKit's rendering cache pushes the footprint past the guard
        // over a full run.
        if config.wants("lele") || config.wants("p2") { try await step("user symptom p2 · scrolling") { try await bench.scrollMarkedVsUnmarked() } }
        if config.wants("lele") || config.wants("p4") { try await step("user symptom p4 · divider") { try await bench.dividerDrag() } }
        if config.wants("lele") || config.wants("p3") { try await step("user symptom p3 · selection") { try await bench.textSelection() } }
        if config.wants("lele") || config.wants("p1") { try await step("user symptom p1 · analysis") { try await bench.analysisRunning() } }
        if config.wants("scroll") { try await step("scroll") { try await bench.scrollPDF(); try await bench.scrollPanel() } }
        if config.wants("hover") { try await step("hover") { try await bench.hoverPDF(); try await bench.hoverPanel(); try await bench.hoverBlocks() } }
        if config.wants("marks") { try await step("marks") { try await bench.markAddRemove() } }
        if config.wants("note") { try await step("note") { try await bench.note() } }
        if config.wants("zoom") { try await step("zoom") { try await bench.zoomBurst() } }
        if config.wants("jump") { try await step("jump") { try await bench.pageJump() } }
        if config.wants("sidebar") { try await step("sidebar") { try await bench.sidebarToggle() } }
        if config.wants("map") { try await step("map") { try await bench.mapOpen() } }
        if config.wants("open") { try await step("open") { try await bench.firstPaintAndSwitch() } }
        // PDF ↔ panel alignment offset (not a timing).
        if config.wants("align") { try await bench.alignment() }
        } catch {
            if holdSeconds > 0 {
                print("F5 BENCH: error, keeping the process alive for \(Int(holdSeconds)) s for the memory sampler — \(error)")
                try? await host.pump(seconds: holdSeconds)
            }
            throw error
        }
        if holdSeconds > 0 {
            print("F5 BENCH: measurements finished, keeping the process alive for \(Int(holdSeconds)) s for the memory sampler")
            try? await host.pump(seconds: holdSeconds)
        }

        report.fact("memory at the end of the measurements", host.memoryGuard.summary)
        let markdown = report.markdown()
        print("\n===== F5 BENCH =====\n\(markdown)\n===== END F5 BENCH =====")
        if let url = report.save(slug: "F5-bench-\(Self.buildConfiguration.lowercased())-\(config.pdfURL.deletingPathExtension().lastPathComponent)") {
            print("F5 BENCH: report saved in \(url.path)")
        }
        #expect(!report.rows.isEmpty)
    }
}
}
