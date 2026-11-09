import XCTest

/// #365: the lodging module's contract (`plugin/rules/modules/lodging.md`), its spec, the shared
/// rules and the entry points that cite it are text a model follows, so no code path tests them.
/// These pins keep each follow-up rule of #365 in the documents it belongs to: a later edit that
/// drops one turns its row red. They pin presence, not meaning; the wording is reviewed by hand.
final class LodgingModuleDocsTests: XCTestCase {
    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("package root not found")
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: try repoRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    private let lodging = "plugin/rules/modules/lodging.md"
    private let lodgingSpec = "openspec/specs/lodging-module/spec.md"
    private let conference = "plugin/rules/modules/conference.md"
    private let shared = "plugin/rules/event-modules.md"
    private let archive = "plugin/skills/archive-event/SKILL.md"
    private let management = "plugin/skills/calendar-management/SKILL.md"
    private let archivingSpec = "openspec/specs/event-source-archiving/spec.md"
    private let conferenceSpec = "openspec/changes/add-conference-module/specs/conference-module/spec.md"

    /// (document, phrase, the #365 item it pins). One row per rule. Each phrase occurs exactly once in
    /// its document, so removing the rule removes the only copy and turns the row red.
    private var pins: [(String, String, String)] {
        [
            // Authority and trust
            (lodging, "`forwarded: sender and date unverified`", "a forwarded sender and date are flagged"),
            (lodgingSpec, "SHALL show a sender or a date shown only in the body as unverified", "forged forward (spec)"),
            (lodging, "**Known limitation:** the module cannot verify who sent a mail.", "a header From: is not verified"),
            (lodging, "`DMARC not pass`: the topmost `Authentication-Results` header, the one the user's own receiving server added", "only the receiver's own Authentication-Results counts (round 2 #4)"),
            (lodgingSpec, "Only the topmost `Authentication-Results` header, added by the user's receiving server, SHALL count", "Authentication-Results (spec, round 2 #4)"),
            (lodging, "**A marker is not proof of who wrote it.**", "the marker line is a forgeable text"),
            (lodging, "begins with a marker prefix that the shared rule \"Copied text never forms a marker\" lists", "another module's marker planted by copied text"),
            (conference, "begins with a marker prefix that the shared rule \"Copied text never forms a marker\" lists", "cross-module marker escape (conference)"),
            (shared, "the marker prefixes of the modules in the table above, and only these", "cross-module marker escape: the one list"),
            (conferenceSpec, "beginning with a marker prefix that the index of event modules lists", "cross-module marker escape (conference spec)"),
            (lodging, "**Secrets never go into the notes, the questions, the tables or the report**", "no secret filter on questions and tables"),
            (lodging, "is left out as if it were one", "a value that may be a secret fails closed"),
            (lodgingSpec, "SHALL NOT show a secret in a question, a table or the report", "secret filter (spec)"),
            (lodging, "**inside quotation marks** (`Bring:", "sender text quoted, not verbatim"),
            (lodging, "a record with the number and another property (a reused number), a record written before #365", "a cancellation record keyed by the number alone"),
            (lodging, "**percent-encoded**", "state keys one-to-one (round 1 M1)"),
            (lodgingSpec, "so that two numbers never share a key", "state keys one-to-one (spec)"),
            (archive, "so `AB/12` and `AB_12` get different keys", "state keys one-to-one (archive-event)"),
            (archivingSpec, "normalised and percent-encoded (every UTF-8 byte other than ASCII", "state keys one-to-one (archiving spec, round 2 #14)"),
            (archive, "\"property\": \"examplehoteltokyo\"", "cancellation record value shape (archive-event)"),
            (archivingSpec, "`property` (the normalised property name), `check_in` and `check_out` (the deleted stay's days)", "cancellation record value shape (spec delta)"),
            (archive, "**The state file holds private trip data**", "state file privacy note (round 1 LOW)"),
            (lodging, "**Thread membership is not authority.**", "References / In-Reply-To decide a thread"),
            (lodging, "9. `Accepted senders:`", "accepted senders on their own line (round 1 M2)"),
            (lodging, "**A copied subject cannot plant a field**", "subject tokens escaped (round 1 M2)"),
            (lodgingSpec, "with `· ` written in front of each of the tokens `accepted senders:`", "subject tokens escaped (spec)"),
            // Search and dedup
            (lodging, "whose nights share at least one night with the statement's", "overlapping dates defined as overlapping nights"),
            (lodging, "the `unconfirmed` marker hits of steps 1 and 2", "the search order reaches the unconfirmed upgrade"),
            (lodging, "**The user asks to update a confirmed stay**", "no path for \"I changed it by phone\""),
            (lodging, "and the title's night count and check-out day recomputed", "phone change recomputes the title (round 1 LOW)"),
            (lodging, "`changed by the user on <date and time>`: on every row for an event the user changed", "a mail after a phone change asks (round 2 #8)"),
            (management, "changed or deleted only through the lodging module", "calendar-management bypasses the #364 end rule"),
            (management, "a cleanup or a migration included", "stays go only through the module in every workflow (round 2 #16)"),
            (lodging, "**The user asks to delete a stay**", "the module's path for a user-requested delete (round 1 LOW)"),
            (lodging, "and for a change notice also over the previous dates it quotes", "a legacy booking rescheduled by another message"),
            (lodging, "a trip-wide or holiday event never hides the gap", "nights without a booking: all calendars, never hidden (round 2 #6)"),
            (lodging, "never updated, adopted or deleted", "an event with the marker line twice"),
            (lodging, "while one carries an `unconfirmed` marker for the same property", "the double-marker guard covers unconfirmed events (round 1 LOW)"),
            (lodging, "to read each one's number or `unconfirmed` property for the guard of section 4", "parsing vs. counting and reading markers (round 2 #20)"),
            (lodging, "a cancellation notice that finds a record that counts for it (the same number and the same property) is reported as already cancelled and asks nothing", "a second cancellation"),
            (lodging, "Everything else is parsed only above the marker line", "labelled lines parsed outside the module's half"),
            (lodging, "**What a mail may change without a question.**", "every mail-driven date move or delete asks (round 2 decision)"),
            (lodging, "3. **Applied without a question**, and only these two:", "the two writes that do not ask (round 2 decision)"),
            (lodging, "A cancellation notice that finds its event always reaches section 7's question", "a cancellation reaches the deletion question (round 1 HIGH)"),
            (lodgingSpec, "(a cancellation notice SHALL never be unchanged this way)", "the same-fields shortcut (spec, round 1 HIGH)"),
            (lodgingSpec, "#### Scenario: A cancellation notice that states only the stay's own fields", "the HIGH scenario"),
            (lodging, "Each check below only adds a flag to the message's row; no flag, and no missing flag, skips the question.", "checks are flags only (round 2 decision)"),
            (lodgingSpec, "SHALL only add flags to the table and SHALL NOT skip the question", "checks are flags only (spec, round 2 decision)"),
            (lodging, "`free-mail or shared mailbox domain`: the domain is one of these, and only these:", "a closed free-mail list, with regional providers (round 2 #9 #17)"),
            (lodging, "on later updates); **no marker**", "a skipped create with the same number and other content"),
            (lodging, "(`unchanged` only when nothing differs;", "a skipped create is compared by the change checks"),
            // Shared rules, entry points, documents
            (shared, "an unclear order, a change from a mail)", "nobody to ask covers any change from a mail (round 3 #17)"),
            (conferenceSpec, "### Requirement: The conference module follows the shared rules of the event modules", "shared rules change conference with no requirement"),
            (conferenceSpec, "the conference module SHALL NOT offer it for adoption or update it as a hand-built event", "the shared-rules requirement's body (round 1 LOW)"),
            (conference, "never counts as \"No marker\" when `create_event` answers `skipped`", "a stay is never a hand-built event to the conference module (round 1 M3)"),
            (archive, "keyword `-module:`, which matches both modules' markers", "the mapped event's notes are read for both markers (round 2 #1)"),
            (lodging, "Normative source: [`openspec/specs/lodging-module/spec.md`]", "the contract points at the archived spec"),
            (lodging, "the nights of the event's span", "title night count when rooms' nights differ"),
            (lodging, "**A cancellation notice never adopts.**", "adoption yes mixed with deletion yes"),
            (lodging, "4. **Everything else asks once**", "a confirmation with other dates, a reminder, a change notice ask (round 2 #3 #8)"),
            (lodging, "The flags are these, and only these:", "the flags are a closed list"),
            (lodging, "the source line is moved to it (the one write this step makes)", "a newer identical mail advances the source line (round 2 #7)"),
            (lodging, "`hinet.net`", "regional shared domains are on the list (round 2 #17)"),
            (lodgingSpec, "Only two writes from a mail SHALL be applied without a question", "the decision (spec)"),
            (lodgingSpec, "#### Scenario: A confirmation with other dates", "the round 2 #3 scenario"),
            (lodging, "keyed `user-request-<the request's date and time in UTC, YYYYMMDDTHHMMSSZ>#lodging:<reservation>`", "a user delete's record key and time (round 2 #2 #15)"),
            (archive, "a record of a delete the user asked for is keyed `user-request-", "a user delete's record key (archive-event)"),
            (archivingSpec, "SHALL key a record of a delete the user asked for", "a user delete's record key (archiving spec)"),
            (lodging, "Any other message that meets a `by_user` record is never superseded by it", "a user delete never silently blocks a rebuild (round 2 #22)"),
            (lodging, "so a different spelling never creates a second stay without a question", "near-name stays in the table (round 2 #5)"),
            (lodgingSpec, "under a differently spelled property name", "near-name stays (spec)"),
            (lodging, "**The reused-number check**", "the search step that cancellation refers to is named (round 2 #11 #24)"),
            (lodging, "`changed by the user on <date and time of the request, with offset>`", "a phone change records its time (round 2 #12)"),
            (lodging, "so the subject cannot end early", "a closing quote in the subject (round 2 #13)"),
            (lodging, "to one canonical string", "one canonical normalised form (round 2 #14)"),
            (lodging, "`(forwarded by …)` and `changed by the user on …`; and the `Accepted senders:` line", "the parse list has the source line's markers (round 2 #18)"),
            (lodging, "a change notice that finds a record that counts is shown next to it and asked about", "a change notice meets a cancellation record (round 2 #19)"),
            (shared, "An event that carries the markers of two modules belongs to neither", "two modules' markers (round 2 #21)"),
            (conference, "one that carries both modules' markers is never updated", "two modules' markers (conference)"),
            (conferenceSpec, "an event that carries both modules' markers SHALL NOT be updated by the conference module", "two modules' markers (conference spec)"),
            (lodging, "**An event that also carries another module's marker**", "two modules' markers (lodging)"),
            (lodging, "**Other changes the user asks for**, and only these:", "the user's legitimate edits (round 2 #23)"),
            (lodging, "**Every move, replacement or rewrite of the source line keeps its `changed by the user on …` tail**", "the user-change tail survives (round 3 #1 #12)"),
            (lodging, "**An older mail is never dropped for its age alone**", "no superseded as a whole (round 3 #2)"),
            (lodgingSpec, "#### Scenario: An older change notice fills in a missing field", "older change notice asks (round 3 #2)"),
            (lodgingSpec, "- **THEN** a before and after table is shown, and after the user's yes the same event is updated to start", "a change of dates asks (round 3 #3)"),
            (lodgingSpec, "shows the before and after table and updates it after the user's yes", "a far move asks (round 3 #3)"),
            (lodgingSpec, "the before and after table, which every change notice gets, carries the flag `sender not seen before`", "other domain is only a flag (round 3 #3)"),
            (lodging, "the before/after table is shown and the user is asked (section 4, step 4); after the user's yes, `update_event` with", "the worked example asks (round 3 #3)"),
            (lodging, "A partly cancelled or changed booking is a change notice: it asks with the before/after table", "partial room change asks (round 3 #4)"),
            (lodgingSpec, "SHALL be a change notice that asks with the before and after table, and on yes SHALL update the notes", "partial room change asks (spec)"),
            (lodging, "**The known-sender condition** holds only when the message's own header `From:`", "free mail and forwards never meet the gate (round 3 #5)"),
            (lodging, "A free-mail or shared mailbox domain is never added;", "no free-mail on Accepted senders (round 3 #5)"),
            (lodgingSpec, "a free-mail domain SHALL NOT be added", "no free-mail on Accepted senders (spec)"),
            (lodgingSpec, "#### Scenario: The same confirmation from a free-mail domain", "free-mail confirmation asks (round 3 #5 #11)"),
            (lodging, "so is a module event at the same property that shares a night with the booking under another reservation number;", "same place, other number asks (round 3 #6)"),
            (lodging, "only when the user says it is a second booking, create again", "skipped create with another number asks (round 3 #6)"),
            (lodging, "a change it would make to an existing event (an unconfirmed stay's dates included) is a write from a mail and asks", "a no-number mail never moves dates silently (round 3 #7)"),
            (lodging, "only for a statement the user makes (a mail treated as a statement asks, section 3)", "statement update only from the user (round 3 #7)"),
            (management, "`copy_event` (a copy would carry the marker and make two stays)", "every touching tool named (round 3 #8)"),
            (lodging, "that the reused-number check of search step 5 did not flag", "step 3 excludes reused-number and other-calendar hits (round 3 #9)"),
            (lodging, "by that module's own marker-line test", "counting another module's marker (round 3 #14)"),
            (lodging, "such a message never takes steps 2 or 3", "thread-only messages always ask (round 3 #15)"),
            (lodging, "is reported as already deleted by the user and asks nothing", "by_user meets a cancellation (round 3 #16)"),
            (conference, "the module creates nothing in its place, and the user is asked", "two markers: conference creates nothing (round 3 #13)"),
            (archive, "the event belongs to neither module: list it and ask, and build nothing", "archive-event checks both markers first (round 3 #13)"),
            (lodging, "(its fields are listed there)", "section 7 no longer lists the old record fields (round 1 LOW)"),
        ]
    }

    func testEveryFollowUpRuleOf365IsInItsDocument() throws {
        var texts: [String: String] = [:]
        for (document, phrase, item) in pins {
            if texts[document] == nil { texts[document] = try read(document) }
            let count = texts[document]!.components(separatedBy: phrase).count - 1
            XCTAssertEqual(count, 1, "\(document) holds the rule for \(item) \(count) times, not once (\(phrase))")
        }
    }

    /// Round 2 #10 and #14: the CHANGELOG no longer states the old check order, and every file that
    /// states the key's byte rule uses the same words.
    func testNoStaleCheckOrderAndOneByteRule() throws {
        XCTAssertFalse(try read("plugin/CHANGELOG.md").contains("(Message-ID, identical content, sender, order)"))
        for document in [lodging, lodgingSpec, archive, archivingSpec] {
            XCTAssertTrue(try read(document).contains("other than ASCII `A`–`Z`, `a`–`z` and `0`–`9`"), document)
        }
    }

    /// The marker prefixes are listed in one place, the shared rule; the two contracts refer to it.
    func testTheEscapedPrefixesAreListedOnce() throws {
        XCTAssertTrue(try read(shared).contains("and only these: `conference-` (marker lines and block lines), `lodging-module`"))
        XCTAssertFalse(try read(shared).contains("and only these: `conference-module`, `lodging-module`"))
        for document in [lodging, conference, conferenceSpec, lodgingSpec] {
            XCTAssertFalse(try read(document).contains("(`lodging-module`, `conference-module`)"), document)
            XCTAssertFalse(try read(document).contains("(`conference-module`, `lodging-module`)"), document)
        }
    }

    /// The contract no longer names the change folder it was written in (it is archived).
    func testTheContractDoesNotPointAtTheUnarchivedChange() throws {
        XCTAssertFalse(try read(lodging).contains("openspec/changes/add-lodging-module/"))
    }

    /// A rule list that a reader could extend stays closed: the secret kinds are stated as the
    /// only ones, and the escaped prefixes are those of the modules in the index.
    func testTheClosedListsSayTheyAreClosed() throws {
        let text = try read(lodging)
        XCTAssertTrue(text.contains("The kinds are these, and only these:"))
        XCTAssertTrue(try read(shared).contains("the marker prefixes of the modules in the table above, and only these"))
    }
}
