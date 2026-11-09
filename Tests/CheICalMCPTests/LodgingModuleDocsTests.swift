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
            (lodging, "**A forwarded message's sender is unverified.**", "a forwarded message's sender and date shown only in the body"),
            (lodgingSpec, "SHALL treat a sender or a date shown only in the body as unverified", "forged forward (spec)"),
            (lodging, "**A header `From:` is not verified either.**", "a header From: is not verified (round 1 M4)"),
            (lodging, "unless that header shows `dmarc=pass` for the sender's domain", "Authentication-Results asks (round 1 M4)"),
            (lodgingSpec, "SHALL NOT treat a header `From:` as verified", "header From: (spec, round 1 M4)"),
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
            (archivingSpec, "percent-encoded (every UTF-8 byte other than a letter or a digit", "state keys one-to-one (archiving spec)"),
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
            (lodging, "is shown in the before/after table as dated before the user's change", "an older booking mail cannot undo a phone change (round 1 LOW)"),
            (management, "changed or deleted only through the lodging module", "calendar-management bypasses the #364 end rule"),
            (management, "a delete the user asks for is the module's section 7", "a user-requested delete goes through the module (round 1 LOW)"),
            (lodging, "**The user asks to delete a stay**", "the module's path for a user-requested delete (round 1 LOW)"),
            (lodging, "and for a change notice also over the previous dates it quotes", "a legacy booking rescheduled by another message"),
            (lodging, "as possibly booked", "nights without a booking read all calendars"),
            (lodging, "never updated, adopted or deleted", "an event with the marker line twice"),
            (lodging, "while one carries an `unconfirmed` marker for the same property", "the double-marker guard covers unconfirmed events (round 1 LOW)"),
            (lodging, "the whole text is read only to count the lines that start with `lodging-module:`", "parsing above the marker vs. counting markers (round 1 LOW)"),
            (lodging, "a cancellation notice that finds a record that counts for it (the same number and the same property) is reported as already cancelled and asks nothing", "a second cancellation"),
            (lodging, "Everything else is parsed only above the marker line", "labelled lines parsed outside the module's half"),
            (lodging, "**First decide what the message is**", "the notice's action is decided first (round 1 HIGH)"),
            (lodging, "**only for a confirmation or a change notice**", "the same-fields shortcut skips cancellations (round 1 HIGH)"),
            (lodging, "**a cancellation notice that finds its event always goes through**", "a cancellation reaches the deletion question (round 1 HIGH)"),
            (lodgingSpec, "SHALL NOT end as unchanged because its stated fields match", "the same-fields shortcut (spec, round 1 HIGH)"),
            (lodgingSpec, "#### Scenario: A cancellation notice that states only the stay's own fields", "the HIGH scenario"),
            (lodging, "**A yes to the sender question clears only the sender**", "the sender yes does not skip the order check (round 1 M5)"),
            (lodgingSpec, "whose yes SHALL clear only the sender and SHALL NOT undo the order check", "the order check (spec, round 1 M5)"),
            (lodging, "the free-mail domains are these, and only these:", "a closed free-mail list (round 1 LOW)"),
            (lodging, "on later updates); **no marker**", "a skipped create with the same number and other content"),
            (lodging, "(`unchanged` only when nothing differs;", "a skipped create is compared by the change checks"),
            // Shared rules, entry points, documents
            (shared, "a change from an unexpected sender", "nobody to ask omits the unexpected sender"),
            (conferenceSpec, "### Requirement: The conference module follows the shared rules of the event modules", "shared rules change conference with no requirement"),
            (conferenceSpec, "the conference module SHALL NOT offer it for adoption or update it as a hand-built event", "the shared-rules requirement's body (round 1 LOW)"),
            (conference, "never counts as \"No marker\" when `create_event` answers `skipped`", "a stay is never a hand-built event to the conference module (round 1 M3)"),
            (archive, "and it holds no `lodging-module:` marker line either", "conference paragraph and a single event archived before the module"),
            (lodging, "Normative source: [`openspec/specs/lodging-module/spec.md`]", "the contract points at the archived spec"),
            (lodging, "the nights of the event's span", "title night count when rooms' nights differ"),
            (lodging, "**A cancellation notice never adopts.**", "adoption yes mixed with deletion yes"),
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

    /// The marker prefixes are listed in one place, the shared rule; the two contracts refer to it.
    func testTheEscapedPrefixesAreListedOnce() throws {
        XCTAssertTrue(try read(shared).contains("and only these: `conference-module`, `lodging-module`"))
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
