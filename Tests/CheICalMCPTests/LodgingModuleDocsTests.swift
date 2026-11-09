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
            (lodging, "`DMARC not pass`: the topmost `Authentication-Results` header does not show", "only the topmost Authentication-Results counts (round 2 #4)"),
            (lodging, "a pass is a hint, never a reason to skip the question", "a planted header cannot skip a question (round 5 #4)"),
            (lodgingSpec, "Only the topmost `Authentication-Results` header SHALL count for the DMARC flag", "Authentication-Results (spec, round 2 #4, round 5 #4)"),
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
            (lodging, "**Copied text cannot plant a field in the source line**", "subject and forwarded body tokens escaped (round 1 M2, round 5 #8)"),
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
            (lodging, "3. **Applied without a question**: a **create** (a new stay, search step 4 (c)), and only that.", "only a create does not ask (round 5 decision)"),
            (lodging, "**every write from a mail to an existing stay**", "every write to an existing stay asks (round 5 decision)"),
            (lodging, "A cancellation notice that finds its event always reaches section 7's question", "a cancellation reaches the deletion question (round 1 HIGH)"),
            (lodgingSpec, "(a cancellation notice SHALL never be unchanged this second way)", "the same-fields shortcut (spec, round 1 HIGH, round 5 #14)"),
            (lodgingSpec, "#### Scenario: A cancellation notice that states only the stay's own fields", "the HIGH scenario"),
            (lodging, "Each check below only adds a flag to the message's row; no flag, and no missing flag, skips the question.", "checks are flags only (round 2 decision)"),
            (lodgingSpec, "SHALL only add flags to the table and SHALL NOT skip the question", "checks are flags only (spec, round 2 decision)"),
            (lodging, "`free-mail or shared mailbox domain`: the domain is one of these, and only these:", "a closed free-mail list, with regional providers (round 2 #9 #17)"),
            (lodging, "on later updates); when the user says it is the same stay", "a skipped create with another number, then the same stay (round 5 #11)"),
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
            (lodging, "`unchanged`, no question, nothing written; the source line stays as it is.", "an identical mail moves nothing (round 5 decision)"),
            (lodging, "`hinet.net`", "regional shared domains are on the list (round 2 #17)"),
            (lodgingSpec, "The only write from a mail applied without a question SHALL be a create", "the decision (spec, round 5)"),
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
            (lodging, "`(claims to be from …)` and `changed by the user on …`; and the `Accepted senders:` line", "the parse list has the source line's markers (round 2 #18)"),
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
            (lodging, "A free-mail or shared mailbox domain is never added, and neither is a sender shown only in the body;", "no free-mail or claimed sender on Accepted senders (round 3 #5, round 4 #4)"),
            (lodgingSpec, "a free-mail domain SHALL NOT be added", "no free-mail on Accepted senders (spec)"),
            (lodgingSpec, "#### Scenario: The same confirmation from a free-mail domain", "free-mail confirmation asks (round 3 #5 #11)"),
            (lodging, "so is a module event at the same property that shares a night with the booking under another reservation number;", "same place, other number asks (round 3 #6)"),
            (lodging, "only when the user says it is a second booking, create again", "skipped create with another number asks (round 3 #6)"),
            (lodging, "a change it would make to an existing event (an unconfirmed stay's dates included) is a write from a mail and asks", "a no-number mail never moves dates silently (round 3 #7)"),
            (lodging, "only for a statement the user makes (a mail treated as a statement asks, section 3)", "statement update only from the user (round 3 #7)"),
            (management, "`copy_event` (a copy would carry the marker and make two stays)", "every touching tool named (round 3 #8)"),
            (lodging, "by that module's own marker-line test", "counting another module's marker (round 3 #14)"),
            (lodging, "such a message never takes steps 2 or 3", "thread-only messages always ask (round 3 #15)"),
            (lodging, "is reported as already deleted by the user and asks nothing", "by_user meets a cancellation (round 3 #16)"),
            (conference, "the module creates nothing in its place, and the user is asked", "two markers: conference creates nothing (round 3 #13)"),
            (archive, "the event belongs to neither module: list it and ask, and build nothing", "archive-event checks both markers first (round 3 #13)"),
            (lodgingSpec, "#### Scenario: A planted Authentication-Results header", "a planted header asks (round 5 #4)"),
            (lodgingSpec, "#### Scenario: A forwarded confirmation from a known forwarder", "a forwarded mail asks (round 5 #3)"),
            (lodgingSpec, "#### Scenario: Trust planted before the booking", "pre-planted trust is shown and reset (spec, round 5 #5)"),
            (lodgingSpec, "#### Scenario: A restated stay found in another calendar", "a restated stay in another calendar asks (spec, round 5 #1)"),
            (lodgingSpec, "#### Scenario: A confirmation dated in the future", "a future Date asks before a create (spec, round 5 #2)"),
            (lodgingSpec, "#### Scenario: A known sender's confirmation with another amount", "a known sender still asks, with a differing field (round 5 #13)"),
            (lodging, "**Trust planted before the booking**", "pre-planted trust is shown and reset (round 5 #5)"),
            (lodging, "**An event the module wrote itself** is one the entry point's state names", "what the module wrote itself (round 5 #5)"),
            (lodging, "**A hit in another calendar** is shown with its calendar and is updated only after the user confirms it", "a restated stay in another calendar asks (round 5 #1)"),
            (lodging, "**The same stay under two numbers.**", "what a same-stay answer does (round 5 #11)"),
            (lodging, "A create from a message whose `Date` is not trusted or missing", "a future or missing Date asks before a create (round 5 #2)"),
            (management, "No workflow creates, outside the module, an event whose notes carry a `lodging-module:` marker line", "no create carries a stay marker (round 5 #6)"),
            (archive, "not §3's single-event line", "a stay's source line is the module's (round 5 #15)"),
            (lodging, "the sender is the forwarding message's own header `From:` (the comparison sender of section 4)", "forwarded: the forwarder is compared (round 4 #4 #5)"),
            (lodging, "the claimed domain is shown, never compared, and never added to `Accepted senders:`", "forwarded claimed domain is display only (round 4 #4)"),
            (lodgingSpec, "the claimed sender SHALL only be displayed, never compared and never added", "forwarded claimed domain (spec, round 4 #4)"),
            (lodgingSpec, "#### Scenario: The same stay under the platform's and the property's numbers", "skipped another-number asks (round 4 #2)"),
            (lodgingSpec, "SHALL show it in the possible-match table and ask once whether it is the same stay", "skipped another-number asks (spec, round 4 #2)"),
            (lodging, "`superseded` for a confirmation dated before a cancellation record (section 4);", "report superseded definition (round 4 #7b, round 5)"),
            (lodging, "to count the `lodging-module:` lines and to apply each other module's own marker-line test", "parse paragraph matches counting rule (round 4 #9)"),
            (lodging, "or states the record's check-in and check-out days", "cancellation record compares dates (round 4 #10)"),
            (lodging, "and when that finds no hit, every calendar over the same range", "statement search widens (round 4 #11)"),
            (management, "never by calling directly, outside the module's own steps", "calendar-management wording (round 4 #12)"),
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
    /// Round 5 decision: the no-question confirmation and source-line paths are gone, so nothing
    /// describes them any more.
    func testTheNoQuestionPathsAreGone() throws {
        for document in [lodging, lodgingSpec, management, archive, "plugin/CHANGELOG.md"] {
            let text = try read(document)
            for phrase in ["no-question gate", "known-sender condition", "step 3 (b)", "step-3 (b)", "except two:"] {
                XCTAssertFalse(text.contains(phrase), "\(document) still says \(phrase)")
            }
        }
    }

    func testTheClosedListsSayTheyAreClosed() throws {
        let text = try read(lodging)
        XCTAssertTrue(text.contains("The kinds are these, and only these:"))
        XCTAssertTrue(try read(shared).contains("the marker prefixes of the modules in the table above, and only these"))
    }
}
