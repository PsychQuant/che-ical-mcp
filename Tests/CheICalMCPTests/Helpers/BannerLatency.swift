import Foundation

/// Wall-clock median of an in-process body (#266). One untimed warm-up run, then `runs` timed
/// runs on `ContinuousClock`; the median keeps one descheduled run on a loaded host from deciding
/// the result.
enum BannerLatency {
    static func median(runs: Int, warmUp: Bool = true, _ body: () -> Void) -> Duration {
        precondition(runs > 0, "need at least one timed run")
        if warmUp { body() }
        let clock = ContinuousClock()
        let samples = (0..<runs).map { _ in clock.measure(body) }
        return median(of: samples)
    }

    /// Median of a non-empty sample; the mean of the two middle values for an even count.
    static func median(of samples: [Duration]) -> Duration {
        precondition(!samples.isEmpty, "median of an empty sample")
        let sorted = samples.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
