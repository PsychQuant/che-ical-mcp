import XCTest
@testable import CheICalMCP

/// #578: the series a recurring `create_event` retry refers to when no exclusion check runs.
final class CreateRetryIdentityTests: XCTestCase {
    /// 2026-12-07 10:00 +08:00, the `/RID=` of the edited first occurrence read on iCloud.
    private let requested = Date(timeIntervalSinceReferenceDate: 818_301_600)
    private let firstID = "S/RID=818301600"
    private let title = "#578 weekly"
    private struct Raised: Error {}

    private func facts(title: String? = "#578 weekly", rules: Bool = true, firstStart: Date? = nil) -> ExclusionRetryTarget.SeriesFacts {
        ExclusionRetryTarget.SeriesFacts(hasRecurrenceRules: rules, timeZone: nil, title: title, isAllDay: false, firstStart: firstStart ?? requested)
    }
    private func match(_ id: String, detached: Bool = true, rules: Bool = false, start: Date? = nil) -> ExclusionRetryTarget.Match {
        ExclusionRetryTarget.Match(identifier: id, isDetached: detached, hasRecurrenceRules: rules, timeZone: nil, start: start ?? requested)
    }
    private var request: ExclusionRetryTarget.Request {
        ExclusionRetryTarget.Request(title: title, start: requested, host: TimeZone(identifier: "Asia/Taipei")!)
    }
    private func candidate(_ id: String, detached: Bool = true, rules: Bool = false, allDay: Bool = false, start: Date? = nil) -> CreateRetryIdentity.Candidate {
        CreateRetryIdentity.Candidate(match: match(id, detached: detached, rules: rules, start: start), isAllDay: allDay)
    }

    // MARK: - The skipped answer's identifier

    /// The measured shape: a recurring retry over the series' first occurrence edited in place
    /// answers the series' identifier, where `main` answered the occurrence's.
    func testARecurringRetryOverTheEditedFirstOccurrenceAnswersTheSeries() {
        XCTAssertEqual(CreateRetryIdentity.answeredSeries(recurring: true, match: match(firstID), request: request, series: { _ in self.facts() }), "S")
    }

    /// A one-off request keeps the matched event's identifier, whatever it matched.
    func testAOneOffRequestKeepsTheMatch() {
        var asked = 0
        XCTAssertNil(CreateRetryIdentity.answeredSeries(recurring: false, match: match(firstID), request: request, series: { _ in asked += 1; return self.facts() }))
        XCTAssertEqual(asked, 0)
    }

    /// Every match `resolve` does not take as the series' first occurrence edited in place keeps
    /// `main`'s answer: another series' title, a moved occurrence, an unreadable series, a raise,
    /// and a series matched under its own identifier (nothing to change).
    func testOtherMatchesKeepMainsAnswer() {
        let other: [(ExclusionRetryTarget.Match, (String) throws -> ExclusionRetryTarget.SeriesFacts?)] = [
            (match(firstID), { _ in self.facts(title: "Other") }),
            (match("S/RID=\(818_301_600 - 2 * 86_400)"), { _ in self.facts() }),
            (match(firstID), { _ in self.facts(firstStart: self.requested.addingTimeInterval(-7 * 86_400)) }),
            (match(firstID), { _ in nil }),
            (match(firstID), { _ in self.facts(rules: false) }),
            (match(firstID), { _ in throw Raised() }),
            (match("S", detached: false, rules: true), { _ in self.facts() }),
            (match("ONE", detached: false), { _ in self.facts() }),
        ]
        for (index, (m, lookup)) in other.enumerated() {
            XCTAssertNil(CreateRetryIdentity.answeredSeries(recurring: true, match: m, request: request, series: lookup), "\(index)")
        }
    }

    // MARK: - The retitled first occurrence

    // spec-example: create-retry-edited-first-occurrence / retitled first occurrence
    /// The title lookup missed; the window holds the series' first occurrence, retitled in place.
    func testTheRetitledFirstOccurrenceIsFound() {
        let found = CreateRetryIdentity.retitledFirstOccurrence(
            recurring: true, candidates: [candidate("OTHER", detached: false), candidate(firstID)], isAllDay: false, request: request,
            series: { _ in self.facts() })
        XCTAssertEqual(found, CreateRetryIdentity.Retitled(occurrenceID: firstID, seriesID: "S"))
    }

    /// Not found: a one-off request, another kind, a series with another title or first slot, a
    /// moved occurrence, an event that addresses no occurrence, a raise.
    func testNothingElseIsTakenForARetitledFirstOccurrence() {
        func find(recurring: Bool = true, _ c: CreateRetryIdentity.Candidate, allDay: Bool = false,
                  _ lookup: @escaping (String) throws -> ExclusionRetryTarget.SeriesFacts?) -> CreateRetryIdentity.Retitled? {
            CreateRetryIdentity.retitledFirstOccurrence(recurring: recurring, candidates: [c], isAllDay: allDay, request: request, series: lookup)
        }
        XCTAssertNil(find(recurring: false, candidate(firstID)) { _ in self.facts() })
        XCTAssertNil(find(candidate(firstID, allDay: true)) { _ in self.facts() })
        XCTAssertNil(find(candidate(firstID)) { _ in self.facts(title: "Other") })
        XCTAssertNil(find(candidate(firstID)) { _ in self.facts(firstStart: self.requested.addingTimeInterval(-7 * 86_400)) })
        XCTAssertNil(find(candidate("S/RID=\(818_301_600 - 2 * 86_400)")) { _ in self.facts() })
        XCTAssertNil(find(candidate(firstID, start: requested.addingTimeInterval(20))) { _ in self.facts() })
        XCTAssertNil(find(candidate("S", detached: false, rules: true)) { _ in self.facts() })
        XCTAssertNil(find(candidate(firstID)) { _ in throw Raised() })
    }

    /// The text names both identifiers only in the echoed shape, says nothing was written, and
    /// carries no `<`, `>` or `&` (#166).
    func testTheRetitledText() {
        let text = CreateRetryIdentity.retitledReason(seriesID: "6F2A:9B1C", occurrenceID: "6F2A:9B1C/RID=818301600")
        XCTAssertEqual(text, "An existing series (event ID 6F2A:9B1C) has this title and its first occurrence at this start, and that first occurrence was edited on its own and now has another title (event ID 6F2A:9B1C/RID=818301600), so this server cannot tell whether this request is a retry of that series. Nothing was created or modified; if it is a new series, change its title or start, or create it in Calendar.")
        let hidden = CreateRetryIdentity.retitledReason(seriesID: "S <b>", occurrenceID: "S <b>/RID=1")
        XCTAssertTrue(hidden.hasPrefix("An existing series (list_events shows it) has this title"), hidden)
        XCTAssertTrue(hidden.contains("(the id list_events shows for it)"), hidden)
        XCTAssertFalse(hidden.contains("<") || hidden.contains(">") || hidden.contains("&"))
        XCTAssertEqual(EventKitError.createRetryRetitledFirstOccurrence(seriesId: "6F2A:9B1C", occurrenceId: "6F2A:9B1C/RID=818301600").errorDescription, text)
    }
}
