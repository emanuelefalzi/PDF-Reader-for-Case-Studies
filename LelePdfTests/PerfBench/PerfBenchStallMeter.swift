import Foundation

/// Measures main-thread "stalls" while something asynchronous happens (an
/// analysis arriving, the concept map being built): a 2 ms timer on the main
/// run loop records how much time passes between one tick and the next;
/// every gap above `thresholdMs` is a stretch in which the main thread was
/// busy and the UI frozen. Returns the longest gap (the worst perceived
/// stall) and the sum of the gaps.
@MainActor
final class PerfBenchStallMeter {
    private var timer: Timer?
    private var lastTick: CFAbsoluteTime = 0
    private(set) var maxGapMs: Double = 0
    private(set) var stalledMs: Double = 0
    private(set) var stallCount = 0
    let thresholdMs: Double

    init(thresholdMs: Double = 8) {
        self.thresholdMs = thresholdMs
    }

    func start() {
        stop()
        maxGapMs = 0
        stalledMs = 0
        stallCount = 0
        lastTick = CFAbsoluteTimeGetCurrent()
        let timer = Timer(timeInterval: 0.002, repeats: true) { _ in
            Task { @MainActor in PerfBenchStallMeter.shared?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Self.shared = self
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if Self.shared === self { Self.shared = nil }
    }

    /// Only one active meter at a time (the timer cannot capture `self`,
    /// isolated to the MainActor, in a `@Sendable` closure).
    private static var shared: PerfBenchStallMeter?

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let gapMs = (now - lastTick) * 1000
        lastTick = now
        guard gapMs > thresholdMs else { return }
        stallCount += 1
        stalledMs += gapMs
        maxGapMs = max(maxGapMs, gapMs)
    }
}
