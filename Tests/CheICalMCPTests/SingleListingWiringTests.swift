import XCTest
@testable import CheICalMCP

/// #527: `updateEvent` lists a series once for the #503 baseline and the verdict where they list the
/// same ranges. The listing runs only against an event store, so what a unit test can show is the
/// keeping itself (`SeriesListingMemoTests`); that `seriesOccurrences` reads through it, and where
/// `updateEvent` opens and ends the stretch, is pinned here from the source.
final class SingleListingWiringTests: XCTestCase {
    private func count(_ literal: String, in body: String) -> Int { SourcePins.ranges(of: literal, in: body).count }

    /// `seriesOccurrences` builds the key from everything its listing depends on and makes the
    /// listing inside the keeping's closure: a kept listing is returned before anything is enumerated.
    func testTheListingIsMadeThroughTheKeeping() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift"))
        let body = try XCTUnwrap(SourcePins.body(of: "private func seriesOccurrences(", in: file))
        XCTAssertEqual(count("let key = SeriesListingKey(calendarIdentifier: calendar.calendarIdentifier, eventIdentifier: id,", in: body), 1)
        XCTAssertEqual(count("externalIdentifier: series.externalIdentifier,", in: body), 1)
        XCTAssertEqual(count("ranges: ranges ?? SeriesExceptionsPlanner.listingRanges(for: window))", in: body), 1)
        XCTAssertEqual(count("return seriesListings.listing(for: key) {", in: body), 1)
        // The key's ranges are the ranges the loop lists: the same expression, twice in the body.
        XCTAssertEqual(count("ranges ?? SeriesExceptionsPlanner.listingRanges(for: window)", in: body), 2)
        XCTAssertEqual(count("for range in ranges ?? SeriesExceptionsPlanner.listingRanges(for: window) {", in: body), 1)
        // The series the key names is the one the occurrences are filtered by.
        XCTAssertEqual(count("let series = UndoPostState.OccurrenceIDs(eventIdentifier: id, externalIdentifier: stale.calendarItemExternalIdentifier)", in: body), 1)
        XCTAssertEqual(count("guard UndoPostState.isOccurrence(ids, of: series) else { return }", in: body), 1)
        // Every store call and every result is inside the closure; the function returns nothing else
        // but nil for a series it cannot list.
        let keeping = try XCTUnwrap(body.range(of: "return seriesListings.listing(for: key) {"))
        for inside in ["var listed: [EKEvent] = []", "var seen = FirstSeen<ListedOccurrenceKey>()", "eventStore.predicateForEvents(",
                       "eventStore.enumerateEvents(", "FirstRemainingOccurrence.Candidate(", "return (listed, candidates)"] {
            let range = try XCTUnwrap(body.range(of: inside), inside)
            XCTAssertLessThan(keeping.lowerBound, range.lowerBound, inside)
            XCTAssertEqual(count(inside, in: body), 1, inside)
        }
        // What the function returns: nil for a series it cannot list (before the key is built), else
        // the kept or made listing; the closure's own result is the listing.
        XCTAssertEqual(count("else { return nil }", in: body), 1)
        XCTAssertEqual(count("return nil", in: body), 1)
        XCTAssertEqual(count("return (", in: body), 1)
        let unlistable = try XCTUnwrap(body.range(of: "else { return nil }"))
        let key = try XCTUnwrap(body.range(of: "let key = SeriesListingKey("))
        XCTAssertLessThan(unlistable.lowerBound, key.lowerBound)
        XCTAssertLessThan(key.lowerBound, keeping.lowerBound)
        // The keeping is read here and nowhere else in the file.
        XCTAssertEqual(count("seriesListings", in: file), 1)
    }

    /// The readers still ask `seriesOccurrences` as they did: the baseline with the base ranges, the
    /// verdict with the ranges it resolved.
    func testTheBaselineAndTheVerdictAskTheListingAsBefore() throws {
        let file = SourcePins.code(try SourcePins.source("EventKit/FirstRemainingOccurrence.swift"))
        let baseline = try XCTUnwrap(SourcePins.body(of: "func wholeSeriesBaseline(", in: file))
        XCTAssertEqual(count("seriesOccurrences(of: series, id: id)", in: baseline), 1)
        let verdict = try XCTUnwrap(SourcePins.body(of: "func deletedOccurrenceVerdict(", in: file))
        XCTAssertEqual(count("seriesOccurrences(of: series, id: id, ranges: ranges)", in: verdict), 1)
        XCTAssertEqual(count("seriesOccurrences(", in: verdict), 1)
        // Both read the value facts taken at listing time, not the listed objects.
        XCTAssertTrue(baseline.contains("guard let (_, candidates) = seriesOccurrences("))
        XCTAssertTrue(verdict.contains("guard let (_, candidates) = seriesOccurrences("))
    }

    /// `updateEvent` opens one stretch: from the #509 check's first-slot read (#533) around the
    /// baseline and the verdict, ended before `seriesUpdatePlan` (which lists after a refresh is
    /// requested) and before the first field is assigned.
    func testUpdateEventSharesTheListingFromThe509ReadThroughTheVerdict() throws {
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        let update = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: manager))
        XCTAssertEqual(count("try seriesListings.sharing {", in: update), 1)
        XCTAssertEqual(count("seriesListings", in: update), 1)
        let stretch = try XCTUnwrap(SourcePins.body(of: "try seriesListings.sharing {", in: update))
        // Inside: #533's #509 first-slot read, the baseline, the check, the verdict and its refusals.
        XCTAssertEqual(count("let firstSlot: Date? = needsFirstSlot ? wholeSeriesBaseline(of: masterEvent, id: identifier, viaStandIn: resolved.viaStandIn).slot : nil", in: stretch), 1)
        XCTAssertEqual(count("if RuleEndShift.applies(", in: stretch), 1)
        XCTAssertEqual(count("let proof = try seriesForCheck().map { wholeSeriesBaseline(of: $0.0, id: $0.1, viaStandIn: viaStandInForCheck) }", in: stretch), 1)
        XCTAssertEqual(count("if reach.isWholeSeries, datePlan.datesToWrite != nil {", in: stretch), 1)
        XCTAssertEqual(count("if deletedOccurrenceCheckApplies(changesAccount: crossesAccounts, baseline: baseline) {", in: stretch), 1)
        XCTAssertEqual(count("deletedOccurrenceVerdict(", in: stretch), 1)
        XCTAssertEqual(count("case .unknown(let cause): throw EventKitError.seriesWriteRefused(reason: DeletedOccurrenceCheck.unknownReason(cause))", in: stretch), 1)
        // The two readers are called nowhere else between the stretch and the save.
        XCTAssertEqual(count("deletedOccurrenceVerdict(", in: update), 1)
        XCTAssertEqual(count("wholeSeriesBaseline(", in: stretch), 2, "the #509 read and the baseline")
        XCTAssertEqual(count("wholeSeriesBaseline(", in: update), 2, "and nowhere else in updateEvent")
        // The stretch's code does not suspend, write or record, and asks for no refresh of the store's
        // view. Two series objects are refreshed while it is open, both on the own-id route only: the
        // #509 rule holder and `seriesForCheck()`'s series. On that route #509 reads no first slot
        // (`wholeThroughSeries` excludes it), so both come before the first shared listing; that
        // `seriesForCheck()` refreshes once is pinned in `testTheSeriesIsReadAndRefreshedOnceBeforeTheFirstListing`.
        for outside in ["await", "refreshIfNeeded", "markNeedsRefresh", "seriesUpdatePlan(", "eventStore.save(", "event.title = "] {
            XCTAssertFalse(stretch.contains(outside), outside)
        }
        XCTAssertEqual(count(".refresh()", in: stretch), 1, "the #509 rule holder's, on the own-id route")
        XCTAssertEqual(count("if addressesOwnOccurrence { _ = ruleHolder?.refresh() }", in: stretch), 1)
        XCTAssertEqual(count("let wholeThroughSeries = applyToAll && !addressesOwnOccurrence", in: stretch), 1)
        XCTAssertEqual(count("let needsFirstSlot = RuleEndShift.needsFirstSlot(wholeThroughSeries: wholeThroughSeries,", in: stretch), 1)
        let rules = SourcePins.code(try SourcePins.source("EventKit/RuleEndShift.swift"))
        let needs = try XCTUnwrap(SourcePins.body(of: "static func needsFirstSlot(", in: rules))
        XCTAssertEqual(count("wholeThroughSeries && (endsChecked || monthEndShape)", in: needs), 1)
        // The #509 read comes before the baseline, and the rule holder's refresh before every shared listing.
        let firstRead = try XCTUnwrap(stretch.range(of: "let firstSlot: Date? = needsFirstSlot ? wholeSeriesBaseline("))
        let baselineRead = try XCTUnwrap(stretch.range(of: "let proof = try seriesForCheck().map { wholeSeriesBaseline("))
        let holderRefresh = try XCTUnwrap(stretch.range(of: "if addressesOwnOccurrence { _ = ruleHolder?.refresh() }"))
        XCTAssertLessThan(firstRead.lowerBound, baselineRead.lowerBound)
        XCTAssertLessThan(holderRefresh.lowerBound, firstRead.lowerBound)
        // The series is read (and, through an occurrence's own id, refreshed) by `seriesForCheck`,
        // declared before the stretch (a function declared inside its closure would not be on the
        // actor) and called inside it only.
        let seriesForCheck = try XCTUnwrap(update.range(of: "func seriesForCheck() throws -> (EKEvent, String)? {"))
        let open = try XCTUnwrap(update.range(of: "try seriesListings.sharing {"))
        let plan = try XCTUnwrap(update.range(of: "let seriesPlan = seriesUpdatePlan("))
        let first = try XCTUnwrap(update.range(of: "if let t = title { event.title = t }"))
        let end = update.index(open.lowerBound, offsetBy: stretch.count)
        XCTAssertLessThan(seriesForCheck.lowerBound, open.lowerBound)
        XCTAssertLessThan(end, plan.lowerBound, "the stretch ends before the #263 plan lists")
        XCTAssertLessThan(plan.lowerBound, first.lowerBound)
        XCTAssertEqual(count("seriesForCheck()", in: String(update[update.startIndex..<open.lowerBound])), 1,
                       "before the stretch: the declaration only")
        XCTAssertEqual(count("seriesForCheck()", in: stretch), 2, "inside the stretch: one call per reader")
        XCTAssertEqual(count("seriesForCheck()", in: update), 3, "and nowhere after it: the declaration and those two calls")
        // What the response and the texts read after the stretch is declared before it.
        let declared = try XCTUnwrap(update.range(of: "var deletionsChecked: DeletionCheckHorizon?"))
        XCTAssertLessThan(declared.lowerBound, open.lowerBound)
        XCTAssertEqual(count("var deletionsChecked: DeletionCheckHorizon?", in: update), 1)
    }

    /// PR #531 verify r1: what keeps a listing made inside the stretch good for both readers although
    /// a refresh runs while the stretch is open. Through an occurrence's own id, `seriesForCheck()`
    /// refreshes the series object, and its first call is inside the stretch. Each reader lists
    /// inside the closure of its own `seriesForCheck().map`, so the series is read, and refreshed,
    /// before the first listing; the result is cached, so the second reader's call returns it without
    /// a second refresh between the two listings.
    func testTheSeriesIsReadAndRefreshedOnceBeforeTheFirstListing() throws {
        let manager = SourcePins.code(try SourcePins.source("EventKit/EventKitManager.swift"))
        let update = try XCTUnwrap(SourcePins.body(of: "func updateEvent(", in: manager))
        let stretch = try XCTUnwrap(SourcePins.body(of: "try seriesListings.sharing {", in: update))
        // Two calls in the stretch, one per reader, each opening the closure its reader lists in.
        XCTAssertEqual(count("seriesForCheck()", in: stretch), 2, "one read of the series per reader")
        XCTAssertEqual(count("try seriesForCheck().map {", in: stretch), 2, "each reader lists inside its read's closure")
        let firstRead = try XCTUnwrap(stretch.range(of: "try seriesForCheck().map {"))
        for listing in ["try seriesForCheck().map { wholeSeriesBaseline(", "deletedOccurrenceVerdict("] {
            XCTAssertEqual(count(listing, in: stretch), 1, listing)
            let range = try XCTUnwrap(stretch.range(of: listing), listing)
            XCTAssertLessThanOrEqual(firstRead.lowerBound, range.lowerBound, "the series is read before \(listing) lists")
        }
        XCTAssertEqual(count("let verdict: DeletedOccurrenceCheck.Verdict = try seriesForCheck().map {", in: stretch), 1)
        let verdictRead = try XCTUnwrap(stretch.range(of: "let verdict: DeletedOccurrenceCheck.Verdict = try seriesForCheck().map {"))
        let verdict = try XCTUnwrap(stretch.range(of: "deletedOccurrenceVerdict("))
        XCTAssertLessThan(verdictRead.lowerBound, verdict.lowerBound, "the verdict lists inside its own read of the series")

        // The read itself: a cached result is returned before anything else, the one refresh comes
        // before the result is cached, and nothing else assigns the cache (so nothing clears it).
        XCTAssertEqual(count("var checkSeries: (EKEvent, String)??", in: update), 1)
        XCTAssertEqual(count("checkSeries = ", in: update), 1, "the cache is assigned where the series is read and cleared nowhere")
        let read = try XCTUnwrap(SourcePins.body(of: "func seriesForCheck() throws -> (EKEvent, String)? {", in: update))
        var order: [String.Index] = []
        for step in ["if let cached = checkSeries { return cached }", "if addressesOwnOccurrence { _ = series?.refresh() }",
                     "checkSeries = .some(found)", "return found"] {
            XCTAssertEqual(count(step, in: read), 1, step)
            order.append(try XCTUnwrap(read.range(of: step), step).lowerBound)
        }
        XCTAssertEqual(order, order.sorted(), "cached result, refresh, cache, return: in this order")
        XCTAssertEqual(count(".refresh()", in: read), 1, "one refresh, on the path that is not cached")
        XCTAssertEqual(count("return ", in: read), 2, "the cached result or the one just cached")
    }

    /// A stretch cannot suspend (its closure is not `async`), ends when the closure returns or
    /// throws, and is opened by `updateEvent` alone: every other caller of the listing lists as before.
    func testOnlyUpdateEventOpensAStretchAndItCannotSuspend() throws {
        let memo = SourcePins.code(try SourcePins.source("EventKit/SeriesListingMemo.swift"))
        XCTAssertEqual(count("func sharing<T>(_ checks: () throws -> T) rethrows -> T {", in: memo), 1)
        XCTAssertFalse(memo.contains("async"))
        let sharing = try XCTUnwrap(SourcePins.body(of: "func sharing<T>(", in: memo))
        XCTAssertEqual(count("defer { kept = nil }", in: sharing), 1)
        XCTAssertEqual(count("guard kept == nil else { return try checks() }", in: sharing), 1)
        let listing = try XCTUnwrap(SourcePins.body(of: "func listing(for key: SeriesListingKey, list: () -> Listing) -> Listing {", in: memo))
        XCTAssertEqual(count("guard kept != nil else { return list() }", in: listing), 1)

        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the scan must read the source tree")
        var opened: [String] = [], read: [String] = [], declared: [String] = []
        for file in files {
            let code = SourcePins.code(try String(contentsOf: file, encoding: .utf8))
            opened += Array(repeating: file.lastPathComponent, count: count("seriesListings.sharing", in: code))
            read += Array(repeating: file.lastPathComponent, count: count("seriesListings.listing(", in: code))
            declared += Array(repeating: file.lastPathComponent, count: count("SeriesListingMemo<", in: code))
            XCTAssertEqual(count("seriesListings", in: code),
                           count("seriesListings.sharing", in: code) + count("seriesListings.listing(", in: code) + count("let seriesListings = ", in: code),
                           "\(file.lastPathComponent): the keeping is only declared, opened and read through")
        }
        XCTAssertEqual(opened, ["EventKitManager.swift"])
        XCTAssertEqual(read, ["FirstRemainingOccurrence.swift"])
        XCTAssertEqual(declared.sorted(), ["EventKitManager.swift", "SeriesListingMemo.swift"])
    }
}
