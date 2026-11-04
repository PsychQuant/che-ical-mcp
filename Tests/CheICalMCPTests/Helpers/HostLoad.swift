import Foundation
import XCTest

/// #366: how a wall-clock bound overrun in a test is reported. Under heavy host load (load
/// averages of 130 to 760 on 18 cores, 2026-10-29) the spawn and latency bounds were exceeded with
/// nothing wrong in the code, and the red run looked like a regression. The bound is kept; only an
/// overrun is judged:
/// - within the bound: passes;
/// - over it, and the 1-minute load average per active core exceeds `defaultThreshold` (4.0):
///   `XCTSkip`, with the measurement and the load ("cannot judge");
/// - over it otherwise, including when the load cannot be read: `XCTFail`, with the load.
/// The reader is a closure so each branch is tested with injected values (`HostLoadTests`).
struct HostLoad {
    struct Snapshot: Equatable {
        /// `getloadavg`'s 1-minute average; nil when it could not be read.
        let loadAverage: Double?
        let cores: Int

        var perCore: Double? {
            guard let loadAverage, cores > 0 else { return nil }
            return loadAverage / Double(cores)
        }

        var text: String {
            guard let loadAverage, let perCore else { return "load unknown on \(cores) cores" }
            return String(format: "load %.2f on %d cores (%.2f per core)", loadAverage, cores, perCore)
        }
    }

    enum Verdict: Equatable {
        case withinBound
        case cannotJudge(String)
        case regression(String)
    }

    /// Runnable tasks per core above which an overrun is not judged. The reported failures were
    /// at about 7 to 42; an idle or busy-but-normal host is well below 4.
    static let defaultThreshold = 4.0

    let read: () -> Snapshot

    static let live = HostLoad(read: {
        var averages = [Double](repeating: 0, count: 1)
        let read = getloadavg(&averages, 1)
        return Snapshot(loadAverage: read == 1 ? averages[0] : nil,
                        cores: ProcessInfo.processInfo.activeProcessorCount)
    })

    /// `what` names the measurement and its bound, e.g. "banner arrival 6.200 s, bound 5.0 s".
    static func verdict(exceeded: Bool, what: String, snapshot: Snapshot,
                        threshold: Double = defaultThreshold) -> Verdict {
        guard exceeded else { return .withinBound }
        if let perCore = snapshot.perCore, perCore > threshold {
            return .cannotJudge("\(what): exceeded at \(snapshot.text), above \(threshold) per core; cannot judge the bound on this host (#366)")
        }
        return .regression("\(what): exceeded at \(snapshot.text)")
    }

    func checkWithinBound(_ elapsed: TimeInterval, bound: TimeInterval, _ what: String,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let measured = String(format: "%@ %.3f s, bound %.1f s", what, elapsed, bound)
        try report(Self.verdict(exceeded: !(elapsed < bound), what: measured, snapshot: read()), file: file, line: line)
    }

    func checkNotTimedOut(_ timedOut: Bool, bound: TimeInterval, _ what: String,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let measured = String(format: "%@ timed out, bound %.1f s", what, bound)
        try report(Self.verdict(exceeded: timedOut, what: measured, snapshot: read()), file: file, line: line)
    }

    private func report(_ verdict: Verdict, file: StaticString, line: UInt) throws {
        switch verdict {
        case .withinBound: return
        case .cannotJudge(let message): throw XCTSkip(message, file: file, line: line)
        case .regression(let message): XCTFail(message, file: file, line: line)
        }
    }
}
