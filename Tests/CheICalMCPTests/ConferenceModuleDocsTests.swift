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
            (contract, "When the question names only one set, a yes names that set.", "rename yes with one set (r5 LOW 8)"),
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
            (spec, "the one answer SHALL pick the candidate set, one same-day set or none", "candidate beside same-day sets (spec, r6 LOW 16)"),
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
            (contract, "**A candidate set beside same-day sets.**", "candidate beside same-day sets (r6 LOW 16)"),
            (contract, "the entry point maps the source to no event", "no umbrella event, no mapping (r6 LOW 15)"),
            (spec, "#### Scenario: The chosen set is another conference", "step 2 fallback scenario"),
            (spec, "#### Scenario: A hand-built all-day event of one day of the conference", "umbrella guard scenario"),
            (design, "### 採納從 v1 拿掉（PR #498 第 5 輪，2026-11-09）", "the deferral is recorded"),
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
                     "step 3 runs again in the routed calendar, its rows are asked", "and the hand-built events the table lists for an item; listed"] {
            XCTAssertFalse(contractText.contains(gone), "\(contract): \(gone)")
        }
        let specText = try read(spec)
        for gone in ["adoption SHALL write the marker lines", "until the user agrees to adopt it", "Declining an adoption SHALL NOT create",
                     "#### Scenario: A hand-built umbrella with an inclusive end is adopted"] {
            XCTAssertFalse(specText.contains(gone), "\(spec): \(gone)")
        }
    }
}
