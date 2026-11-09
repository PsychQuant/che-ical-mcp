import XCTest

/// #351 (PR #498 round 5): hand-built adoption is out of v1. The conference contract and its spec are
/// text a model follows, so these pins keep each rule in its document: each phrase must occur exactly
/// once, so removing the rule removes the only copy.
final class ConferenceModuleDocsTests: XCTestCase {
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

    private let contract = "plugin/rules/modules/conference.md"
    private let spec = "openspec/changes/add-conference-module/specs/conference-module/spec.md"
    private let design = "openspec/changes/add-conference-module/design.md"
    private let changelog = "plugin/CHANGELOG.md"
    private let skill = "plugin/skills/archive-event/SKILL.md"
    private let eventModules = "plugin/rules/event-modules.md"

    private var pins: [(String, String, String)] {
        [
            (contract, "**A hand-built event is never adopted, renamed or written**", "no adoption in v1"),
            (contract, "\"hand-built event <event> found; create the item anyway?\"", "one yes/no row per item"),
            (contract, "**Create is never offered where `create_event` would skip or duplicate**", "the duplicate guard"),
            (contract, "a listed all-day event is titled with the official name exactly", "the umbrella guard is narrow (r5 LOW 15)"),
            (contract, "**An event is left out only when every item it may be already has an event**", "the take rule, negative form (r5 #1 #4)"),
            (contract, "**When the chosen set turns out not to be this program's**", "step 2 then builds in the routed calendar (r5 #6)"),
            (contract, "is another conference` when the chosen set turned out not to be this program's, step 2)", "report line 1 says so (r5 #6)"),
            (contract, "**Use** can be chosen for one set only", "step 2 uses one set (r5 LOW 11)"),
            (contract, "When the question names only one set, it is answered by naming that set or by a yes to the rename question itself", "rename yes with one set (r5 LOW 8, r7 #4)"),
            (contract, "**a plain yes to the table never answers it**", "a plain yes never answers a one-set rename (r7 #4)"),
            (spec, "and a plain yes to the table SHALL NOT answer it", "a plain yes never answers a one-set rename (spec, r7 #4)"),
            (spec, "#### Scenario: A one-set rename question and a plain yes", "r7 #4 scenario"),
            (contract, "and for an umbrella that would be updated to other dates or another title", "an updated umbrella's target is searched (r7 #2 #7)"),
            (contract, "**An umbrella that would be updated onto days a listed all-day event covers**", "umbrella update-anyway row (r7 #2 #7)"),
            (contract, "unless step 3 listed an event for it on the new days", "an exact set's umbrella update asks first (r7 #2)"),
            (spec, "SHALL have the same update-anyway row with its own answer", "umbrella update-anyway row (spec, r7 #2)"),
            (spec, "#### Scenario: An exact set's umbrella moves onto a hand-built all-day event", "r7 #2 scenario"),
            (spec, "ignoring all-day events, the program's own events and the old events that rows answered yes map to program items (a clash with a hand-built event the table lists SHALL be reported as the routing requirement states)", "entry-points clash rule (spec, r7 #1 #3, r8 #1 #4)"),
            (contract, "**It needs its own answer whenever it names a hand-built event**", "merged old-event row needs its own answer (r7 LOW 5)"),
            (contract, "the row reads \"no creates the item beside <event>\"", "merged row says what no does (r7 LOW 5)"),
            (contract, "are void and are asked again, as in the step 2 fallback", "same-calendar rerun voids the first table (r7 LOW 6)"),
            (contract, "a **module event of another set** (one step 1's search found, which step 3 skips)", "another set's event holds the slot (r7 LOW 9)"),
            (spec, "a module event of another set with the item's title covering its start", "another set's event holds the slot (spec, r7 LOW 9)"),
            (design, "（已被下方 PR #498 第 6 輪的 (2) 取代：", "design r5 bullet marked replaced (r7 LOW 8)"),
            (contract, "`Umbrella: declined (row answered no)`", "a declined umbrella is reported (r5 LOW 10, r6 LOW 10)"),
            (contract, "*declined* means a hand-built or \"not in the set\" row answered no", "declined covers a not-in-the-set no (r6 LOW 10)"),
            (contract, "An event whose notes hold the pair more than once is not a module event either", "a double-pair event is listed (r5 LOW 16)"),
            (spec, "The module SHALL NOT adopt, rename or write a hand-built event", "no adoption (spec)"),
            (spec, "the run SHALL go back to the routed calendar and run the whole existing-set flow there", "step 2 fallback reruns the flow (spec, r6 #2 #4)"),
            (spec, "the rows answered in the first table SHALL be void and asked again", "first-table answers are void (spec, r6 LOW 6)"),
            (spec, "the hand-built search SHALL run again for the full program, umbrella included", "a same-calendar no reruns step 3 (spec, r6 #5)"),
            (spec, "it SHALL need its own answer, yes SHALL update the old event", "update-anyway row (spec, r6 #1)"),
            (spec, "a clash with a hand-built event the table lists SHALL be reported on a line of its own", "listed hand-built clashes reported (spec, r6 #3)"),
            (spec, "when that set turns out not to be this program's, the run SHALL go back to the routed calendar", "the routing exception (spec, r6 LOW 7)"),
            (spec, "an event whose notes hold the pair more than once SHALL be listed like a hand-built event", "double pair listed (spec, r6 LOW 14)"),
            (spec, "the one answer SHALL pick one of those sets or none", "several sets: one choice (spec, r6 LOW 16, r8 #2)"),
            (spec, "#### Scenario: A rejected set in another calendar, and a set in the routed calendar", "r6 #2 scenario"),
            (spec, "#### Scenario: A set-level no runs the hand-built search again", "r6 #5 scenario"),
            (spec, "#### Scenario: A plain yes and a hand-built row", "r6 LOW 13 scenario"),
            (spec, "#### Scenario: A hand-built event that clashes", "r6 #3 scenario"),
            (contract, "**When the correction would move or rename the old event onto a slot a listed event holds**", "update-anyway row (r6 #1, LOW 12)"),
            (contract, "\"update anyway? (two events would then share the slot)\"", "the update-anyway question (r6 #1)"),
            (contract, "the whole existing-set flow runs again there before anything is built", "step 2 fallback reruns the flow (r6 #2 #4)"),
            (contract, "are void there and are asked again in the new table", "first-table answers are void (r6 LOW 6)"),
            (contract, "**Again after a no in the same calendar.**", "a same-calendar no reruns step 3 (r6 #5)"),
            (contract, "`conflicts already listed in the table: <event> with <session>`", "listed hand-built clashes reported (r6 #3, LOW 11)"),
            (contract, "That exception ends when the chosen set turns out not to be this program's", "the routing exception (r6 LOW 7)"),
            (contract, "A hand-built row needs **its own answer**", "hand-built rows need their own answer (r6 LOW 13)"),
            (contract, "**Several sets: the choice comes first.**", "several sets: one choice (r6 LOW 16, r8 #2)"),
            (contract, "the entry point maps the source to no event", "no umbrella event, no mapping (r6 LOW 15)"),
            (spec, "#### Scenario: The chosen set is another conference", "step 2 fallback scenario"),
            (spec, "#### Scenario: A hand-built all-day event of one day of the conference", "umbrella guard scenario"),
            (design, "### 採納從 v1 拿掉（PR #498 第 5 輪，2026-11-09）", "the deferral is recorded"),
            // PR #498 round 8.
            (contract, "No old event → item row, \"not in the set\" row or hand-built row is computed or asked until it is answered", "several sets: item rows after the choice (r8 #2)"),
            (spec, "no item-level row SHALL be computed or asked until that choice is answered", "several sets: item rows after the choice (spec, r8 #2)"),
            (spec, "#### Scenario: Several sets are listed and the choice comes first", "r8 #2 scenario"),
            (contract, "only when that search found a set in another calendar; when it found none, step 2 asks nothing", "step 2 asks only for a set elsewhere (r8 #3)"),
            (spec, "when it finds none, it SHALL ask nothing at this step", "step 2 asks only for a set elsewhere (spec, r8 #3)"),
            (spec, "#### Scenario: A correction answered no leaves an overlapping old event", "r8 #1 scenario"),
            (changelog, "skipping the old events that rows answered yes map to program items", "clash ignore set (CHANGELOG, r8 #4)"),
            (design, "（已被下方 PR #498 第 8 輪取代：", "design #351 clash sentence marked replaced (r8 #4)"),
            (design, "PR #498 第 8 輪補的", "round 8 recorded in the design"),
            (contract, "except the hand-built rows, an \"update anyway?\" row and an old event's row that names a hand-built event", "plain-yes exceptions (r8 #5)"),
            (spec, "other than the hand-built rows, an update-anyway row and an old event's row that names a hand-built event", "plain-yes exceptions (spec, r8 #5)"),
            (contract, "**Naming the set answers only that choice**", "a rename answer answers no other row (r8 #8)"),
            (spec, "and SHALL answer no other row: the rows of items not in the set and the hand-built rows SHALL need their own answers", "a rename answer answers no other row (spec, r8 #8)"),
            (contract, "; it stays under the old marker <old name> | <old first day>`", "an umbrella left under its old marker is reported (r8 #7)"),
            (skill, "kept, declined, not updated or pending", "no mapping to an umbrella left under the old marker (r8 #7)"),
            (contract, "the conference module counts an event as its own only with both lines", "one-line events are hand-built (r8 #13)"),
            (eventModules, "the conference module counts an event as its own only with both of its lines", "one-line events are hand-built (index, r8 #13)"),
            // PR #498 round 9.
            (contract, "**The umbrella that would be updated counts as lacking here**", "a found all-day event stays listed for the update-anyway row (r9 #1)"),
            (spec, "the umbrella SHALL count as an item the set lacks when it would be updated to other dates or another title", "the update target is not filtered out (spec, r9 #1)"),
            (spec, "#### Scenario: A found all-day event stays listed although the set has an umbrella", "r9 #1 scenario"),
            (contract, "for a timed event with the official or short name that runs over more than one of the program's days (a hand-built conference block), the umbrella as well", "a multi-day timed block is listed for the umbrella (r9 #7)"),
            (spec, "a timed event with the official or short name that runs over more than one of the program's days SHALL also be listed for the umbrella", "a multi-day timed block is listed for the umbrella (spec, r9 #7)"),
            (spec, "#### Scenario: A timed hand-built event spans the conference's days", "r9 #7 scenario"),
            (contract, "**An umbrella of another set on the program's days.**", "an umbrella left under an old marker is named (r9 #3)"),
            (contract, "or, in a calendar chosen in step 2, the step 2 fallback", "several sets in a step 2 calendar (r9 #4)"),
            (contract, "and run step 3 for the corrected items", "a partial correction runs step 3 (r9 #5)"),
            (design, "點名手建事件的舊事件列與「仍要更新嗎」列仍要單獨回答", "design r8 (4) lists the own-answer rows (r9 #6)"),
            (contract, "except an old event whose row was answered no", "a declined correction's old event is clash-checked (r9 #2)"),
            (spec, "an old event of the set whose row was answered no SHALL NOT be ignored", "a declined correction's old event is clash-checked (spec, r9 #2)"),
            (contract, "an answer that leaves a set without one is not an answer", "every step 2 set needs an answer (r9 #8)"),
            (spec, "every set the question lists SHALL need one of these answers", "every step 2 set needs an answer (spec, r9 #8)"),
        ]
    }

    func testEveryRuleIsInItsDocumentOnce() throws {
        var texts: [String: String] = [:]
        for (document, phrase, item) in pins {
            if texts[document] == nil { texts[document] = try read(document) }
            let count = texts[document]!.components(separatedBy: phrase).count - 1
            XCTAssertEqual(count, 1, "\(document) holds the rule for \(item) \(count) times, not once (\(phrase))")
        }
    }

    /// The adoption answers, rows and paragraph are gone from the contract and the spec.
    func testAdoptionIsGone() throws {
        let contractText = try read(contract)
        for gone in ["**Adoption** writes", "**Name-only row**", "**Row naming several events**", "create the item as new",
                     "adopted N", "an adopt answer",
                     // r6 #2: the fallback reruns the whole flow, not step 3 alone; r6 #3: listed hand-built events are not ignored.
                     "step 3 runs again in the routed calendar, its rows are asked", "and the hand-built events the table lists for an item; listed",
                     "When the question names only one set, a yes names that set.",
                     // r8 #2: several sets get one choice row first; r8 #8: a rename answer answers no other row; r8 #12.
                     "Several candidate sets: ask which one", "the same answer applies the table", "no second question follows",
                     "an adopted event's old notes"] {
            XCTAssertFalse(contractText.contains(gone), "\(contract): \(gone)")
        }
        let specText = try read(spec)
        // r7 #1: the entry-points requirement no longer ignores the events the table lists.
        // r8 #1 #4: only old events that rows answered yes map are left out of the clash check; r8 #2 #8.
        for gone in ["maps or lists", "the old events the table maps", "and the table applied", "no second question SHALL follow"] {
            XCTAssertFalse(specText.contains(gone), "\(spec): \(gone)")
        }
        let changelogText = try read(changelog)
        // r8 #6: the r5 "a yes names it" rule is gone from the CHANGELOG too; r8 #4: the clash ignore set.
        for gone in ["A correction that would move an old event onto", "when one set is named a yes names it", "skipping the events the table maps"] {
            XCTAssertFalse(changelogText.contains(gone), "CHANGELOG: \(gone)")
        }
        // r8 #7: an umbrella left under its old marker maps the source to no event.
        XCTAssertFalse(try read(skill).contains("kept, declined or pending"), "\(skill): kept, declined or pending")
        for gone in ["adoption SHALL write the marker lines", "until the user agrees to adopt it", "Declining an adoption SHALL NOT create",
                     "#### Scenario: A hand-built umbrella with an inclusive end is adopted"] {
            XCTAssertFalse(specText.contains(gone), "\(spec): \(gone)")
        }
    }
}
