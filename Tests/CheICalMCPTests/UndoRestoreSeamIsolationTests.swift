import XCTest
@testable import CheICalMCP

/// #476: `EventRestoreCalendar.resolve` and `UndoRestoreDestination.verify` are nonisolated async
/// functions (Swift 5 mode, SE-0338), so after their first `await` the synchronous closures the
/// caller formed on its actor ran off it: `invalidate` (in production `markNeedsRefresh`, which
/// writes the actor's refresh state) and the closures that read the calendars. The seams now run on
/// the caller's actor (`#isolation`), and the probe traps (`preconditionIsolated`, which also checks in -O builds) if any of them runs
/// anywhere else, as PR #474's `testTheCheckAndTheRemovalRunOnTheCallersActor` does.
final class UndoRestoreSeamIsolationTests: XCTestCase {
    func testTheRestoreCalendarSeamRunsItsClosuresOnTheCallersActor() async throws {
        let probe = RestoreSeamProbe(found: "A")
        let found = try await probe.resolveAfterAMiss()
        XCTAssertEqual(found, "A")
        let steps = await probe.steps
        XCTAssertEqual(steps, ["read", "match (isolated)", "invalidate (isolated)", "read", "match (isolated)"])
    }

    func testTheBatchDestinationCheckRunsItsClosuresOnTheCallersActor() async throws {
        let snapshot = UndoSnapshotFixtures.event(title: "Standup")
        let probe = RestoreSeamProbe(found: snapshot.calendarIdentifier)
        try await probe.verifyAfterAMiss(snapshot)
        let steps = await probe.steps
        XCTAssertEqual(steps.filter { !$0.hasPrefix("identifier") && !$0.hasPrefix("writable") },
                       ["read", "invalidate (isolated)", "read"])
        XCTAssertTrue(steps.contains("identifier (isolated)"))
        XCTAssertTrue(steps.contains("writable (isolated)"))
    }

    /// The production callers are methods of the `EventKitManager` actor and pass no isolation, so
    /// `#isolation` gives them the actor; a nil passed by hand would bring the old behavior back.
    func testBothSeamsTakeTheCallersIsolation() throws {
        let param = "isolation: isolated (any Actor)? = #isolation"
        for file in ["EventKit/EventRestoreCalendar.swift", "EventKit/UndoBatchRestore.swift"] {
            XCTAssertTrue(try SourcePins.source(file).contains(param), file)
        }
        let callers = try SourcePins.source("EventKit/EventKitManager.swift") + SourcePins.source("EventKit/EventKitManager+UndoGuard.swift")
        XCTAssertFalse(callers.contains("isolation: nil"))
    }
}

private actor RestoreSeamProbe {
    private(set) var steps: [String] = []
    private var reads = 0
    private let found: String

    init(found: String) { self.found = found }

    private func read() async -> [String] {
        steps.append("read")
        reads += 1
        await Task.yield()
        return reads == 1 ? [] : [found]
    }

    private func note(_ step: String) {
        preconditionIsolated("\(step) must run on the actor that formed it")
        steps.append("\(step) (isolated)")
    }

    func resolveAfterAMiss() async throws -> String {
        try await EventRestoreCalendar.resolve(
            read: { await self.read() },
            invalidate: { self.note("invalidate") },
            match: { calendars in
                self.note("match")
                guard let found = calendars.first(where: { $0 == "A" }) else { throw Missing() }
                return found
            })
    }

    func verifyAfterAMiss(_ snapshot: EventSnapshot) async throws {
        try await UndoRestoreDestination.verify(
            [.eventCalendar(snapshot)],
            identifier: { (calendar: String) -> String in self.note("identifier"); return calendar },
            allowsModifications: { (_: String) -> Bool in self.note("writable"); return true },
            read: { (eventCalendars: await self.read(), reminderLists: [String]()) },
            invalidate: { self.note("invalidate") })
    }

    struct Missing: Error {}
}
