import Foundation

/// State of a block in the per-window queue (SPEC §5.5). `analyzed` comes
/// from the registry (`AnalysisRecord.blocks[id].status`), not tracked
/// internally by the queue.
enum BlockQueueState: Sendable, Equatable {
    case idle
    /// 1-based: position in this window's queue (does not count the block in
    /// progress).
    case queued(position: Int)
    /// Another window is occupying `BatchRunner` (SPEC §6.3).
    case waitingOtherWindow
    case running(startedAt: Date, estimatedSeconds: Double?)
    case failed(ClaudeError)
    case analyzed
}

/// Time estimate (SPEC §5.5 "estimated time (moving average of the latest
/// analyses)"): a handful of recent real durations persisted in `UserDefaults`
/// (they survive an app restart), simple average, default ~26 s (SPEC §4,
/// real measurement). Pure functions on an injected `UserDefaults`: tests use
/// their own domain, never `.standard`.
enum AnalysisETA {
    static let defaultsKey = "analysisRecentDurationsSeconds"
    static let defaultEstimateSeconds: Double = 26
    static let historyCap = 8

    static func estimate(defaults: UserDefaults) -> Double {
        let values = defaults.array(forKey: defaultsKey) as? [Double] ?? []
        guard !values.isEmpty else { return defaultEstimateSeconds }
        return values.reduce(0, +) / Double(values.count)
    }

    static func record(seconds: Double, defaults: UserDefaults) {
        var values = defaults.array(forKey: defaultsKey) as? [Double] ?? []
        values.append(seconds)
        if values.count > historyCap {
            values.removeFirst(values.count - historyCap)
        }
        defaults.set(values, forKey: defaultsKey)
    }
}

/// UserDefaults key for the analysis model (SPEC §5.11: "analysis and chat
/// each have a Sonnet/Opus selector"); this type only reads the key that
/// Settings writes.
enum AnalysisModelPreference {
    static let defaultsKey = "analysisModel"

    static func read(defaults: UserDefaults) -> ClaudeModel {
        guard let raw = defaults.string(forKey: defaultsKey), let model = ClaudeModel(rawValue: raw) else {
            return .sonnet
        }
        return model
    }
}
